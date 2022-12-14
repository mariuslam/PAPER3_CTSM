module mkgridmapMod
!-----------------------------------------------------------------------
!BOP
!
! !MODULE: mkgridmapMod
!
! !DESCRIPTION:
! Module containing 2-d global surface boundary data information
!
! !NOTES:
! Avoid using the frac_src and frac_dst found here, because they
! are read from mapping files, and we have generally moved to "nomask"
! mapping files. This means that mapping files now typically contain
! mask and frac equal to 1 everywhere. So now during remapping we apply the
! source masks found in the raw datasets and ignore the masks found in the
! mapping files. Exception: we continue to use a masked mapping file to regrid
! the 1-km topography.
!
! !USES:
  use shr_kind_mod, only : r8 => shr_kind_r8

  implicit none
  private

! !PUBLIC TYPES:
  type gridmap_type
     character(len=32) :: set ! If set or not
     integer :: na            ! size of source domain
     integer :: nb            ! size of destination domain
     integer :: ns            ! number of non-zero elements in matrix
     real(r8), pointer :: yc_src(:)     ! "degrees" 
     real(r8), pointer :: yc_dst(:)     ! "degrees" 
     real(r8), pointer :: xc_src(:)     ! "degrees" 
     real(r8), pointer :: xc_dst(:)     ! "degrees" 
     real(R8), pointer :: area_src(:)   ! area of a grid in map (radians)
     real(R8), pointer :: area_dst(:)   ! area of b grid in map (radians)
     real(r8), pointer :: frac_src(:)   ! "unitless" 
     real(r8), pointer :: frac_dst(:)   ! "unitless" 
     integer , pointer :: src_indx(:)   ! correpsonding column index
     integer , pointer :: dst_indx(:)   ! correpsonding row    index
     real(r8), pointer :: wovr(:)       ! wt of overlap input cell
  end type gridmap_type
  public :: gridmap_type
!
! !PUBLIC MEMBER FUNCTIONS:
  public :: gridmap_setptrs     ! Set pointers to gridmap data
  public :: for_test_create_gridmap  ! Set a gridmap directly, for testing
  public :: gridmap_mapread     ! Read in gridmap
  public :: gridmap_check       ! Check validity of a gridmap
  public :: gridmap_calc_frac_dst  ! Obtain frac_dst
  public :: gridmap_areaave_no_srcmask  ! do area average without passing mask
  public :: gridmap_areaave_srcmask  ! do area average with mask passed
  public :: gridmap_areaave_scs ! area average, but multiply by ratio of source over destination weight
  public :: gridmap_areastddev  ! do area-weighted standard deviation
  public :: gridmap_clean       ! Clean and deallocate a gridmap structure
!
!
! !REVISION HISTORY:
! Author Mariana Vertenstein

  ! questions - how does the reverse mapping occur 
  ! is mask_dst read in - and what happens if this is very different
  ! from frac_dst which is calculated by mapping frac_src?
  ! in frac - isn't grid1_frac always 1 or 0?

  ! !PRIVATE MEMBER FUNCTIONS:
  private :: set_gridmap_var
  private :: gridmap_checkifset

  interface set_gridmap_var
     module procedure set_gridmap_var_r8
     module procedure set_gridmap_var_int
  end interface set_gridmap_var

  character(len=32), parameter :: isSet = "gridmap_IsSet"
  
!
!EOP
!------------------------------------------------------------------------------
contains

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_setptrs
!
! !INTERFACE:
  subroutine gridmap_setptrs(gridmap, nsrc, ndst, ns, yc_src, yc_dst, &
                             xc_src, xc_dst,  &
                             frac_src, frac_dst, src_indx, dst_indx )
!
! !DESCRIPTION:
! This subroutine assigns pointers to some of the map type data.
!
! !ARGUMENTS:
     implicit none
     type(gridmap_type), intent(in) :: gridmap   ! mapping data
     integer, optional :: nsrc                   ! size of source domain
     integer, optional :: ndst                   ! size of destination domain
     integer, optional :: ns                     ! number of non-zero elements in matrix
     integer,  optional, pointer :: dst_indx(:)  ! Destination index
     integer,  optional, pointer :: src_indx(:)  ! Destination index
     real(r8), optional, pointer :: yc_src(:)    ! "degrees" 
     real(r8), optional, pointer :: yc_dst(:)    ! "degrees" 
     real(r8), optional, pointer :: xc_src(:)    ! "degrees" 
     real(r8), optional, pointer :: xc_dst(:)    ! "degrees" 
     real(r8), optional, pointer :: frac_src(:)  ! "unitless" 
     real(r8), optional, pointer :: frac_dst(:)  ! "unitless" 
!
! !REVISION HISTORY:
!   Created by Erik Kluzek
!
! !LOCAL VARIABLES:
!EOP
!------------------------------------------------------------------------------
     character(*),parameter :: subName = '(gridmap_setptrs) '

     call gridmap_checkifset( gridmap, subname )
     if ( present(nsrc)     ) nsrc     = gridmap%na
     if ( present(ndst)     ) ndst     = gridmap%nb
     if ( present(ns)       ) ns       = gridmap%ns
     if ( present(yc_src)   ) yc_src   => gridmap%yc_src
     if ( present(xc_src)   ) xc_src   => gridmap%xc_src
     if ( present(frac_src) ) frac_src => gridmap%frac_src
     if ( present(yc_dst)   ) yc_dst   => gridmap%yc_dst
     if ( present(xc_dst)   ) xc_dst   => gridmap%xc_dst
     if ( present(frac_dst) ) frac_dst => gridmap%frac_dst
     if ( present(dst_indx) ) dst_indx => gridmap%dst_indx
     if ( present(src_indx) ) src_indx => gridmap%src_indx
  end subroutine gridmap_setptrs

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_mapread
!
! !INTERFACE:
  subroutine gridmap_mapread(gridmap, fileName)
!
! !DESCRIPTION:
! This subroutine reads in the map file
!
! !USES:
    use mkncdio, only : nf_open, nf_close, nf_strerror
    use mkncdio, only : nf_inq_dimid, nf_inq_dimlen
    use mkncdio, only : nf_inq_varid, nf_get_var_double, nf_get_var_int
    use mkncdio, only : NF_NOWRITE, NF_NOERR
    use mkncdio, only : convert_latlon
!
! !ARGUMENTS:
    implicit none
    type(gridmap_type), intent(out) :: gridmap   ! mapping data
    character(len=*)   , intent(in)  :: filename  ! netCDF file to read
!
! !REVISION HISTORY:
!   Created by Mariana Vertenstein
!
! !LOCAL VARIABLES:
    integer :: n       ! generic loop indicies
    integer :: na      ! size of source domain
    integer :: nb      ! size of destination domain
    integer :: igrow   ! aVect index for matrix row
    integer :: igcol   ! aVect index for matrix column
    integer :: iwgt    ! aVect index for matrix element
    integer :: iarea   ! aVect index for area


    character,allocatable :: str(:)  ! variable length char string
    character(len=256)    :: attstr  ! netCDF attribute name string
    integer               :: rcode   ! netCDF routine return code
    integer               :: fid     ! netCDF file      ID
    integer               :: vid     ! netCDF variable  ID
    integer               :: did     ! netCDF dimension ID
    integer               :: ns      ! size of array

    real(r8), parameter   :: tol = 1.0e-4_r8  ! tolerance for checking that mapping data
                                              ! are within expected bounds

    !--- formats ---
    character(*),parameter :: subName = '(gridmap_map_read) '
    character(*),parameter :: F00 = '("(gridmap_map_read) ",4a)'
    character(*),parameter :: F01 = '("(gridmap_map_read) ",2(a,i7))'
!EOP
!------------------------------------------------------------------------------

    !-------------------------------------------------------------------------------
    !
    !-------------------------------------------------------------------------------

    write(6,F00) "reading mapping matrix data..."

    ! open & read the file
    write(6,F00) "* file name                  : ",trim(fileName)

    rcode = nf_open(filename ,NF_NOWRITE, fid)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)

    !--- allocate memory & get matrix data ----------
    rcode = nf_inq_dimid (fid, 'n_s', did)  ! size of sparse matrix
    rcode = nf_inq_dimlen(fid, did  , gridmap%ns)
    rcode = nf_inq_dimid (fid, 'n_a', did)  ! size of  input vector
    rcode = nf_inq_dimlen(fid, did  , gridmap%na)
    rcode = nf_inq_dimid (fid, 'n_b', did)  ! size of output vector
    rcode = nf_inq_dimlen(fid, did  , gridmap%nb)

    write(6,*) "* matrix dimensions rows x cols :",gridmap%na,' x',gridmap%nb
    write(6,*) "* number of non-zero elements: ",gridmap%ns

    ns = gridmap%ns
    na = gridmap%na
    nb = gridmap%nb
    allocate(gridmap%wovr(ns)    , &
             gridmap%src_indx(ns), &
             gridmap%dst_indx(ns), &
             gridmap%area_src(na), &
             gridmap%frac_src(na), &
             gridmap%area_dst(nb), &
             gridmap%frac_dst(nb), &
             gridmap%xc_dst(nb),   &
             gridmap%yc_dst(nb),   &
             gridmap%xc_src(na),   &
             gridmap%yc_src(na), stat=rcode)
    if (rcode /= 0) then
       write(6,*) SubName//' ERROR: allocate gridmap'
       call abort()
    endif

    rcode = nf_inq_varid(fid,'S'  ,vid)
    rcode = nf_get_var_double(fid,vid  ,gridmap%wovr)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)

    rcode = nf_inq_varid(fid,'row',vid)
    rcode = nf_get_var_int(fid, vid  ,gridmap%dst_indx)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)

    rcode = nf_inq_varid(fid,'col',vid)
    rcode = nf_get_var_int(fid, vid, gridmap%src_indx)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)

    rcode = nf_inq_varid(fid,'area_a',vid)
    rcode = nf_get_var_double(fid, vid, gridmap%area_src)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)

    rcode = nf_inq_varid(fid,'area_b',vid)
    rcode = nf_get_var_double(fid, vid, gridmap%area_dst)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)

    rcode = nf_inq_varid(fid,'frac_a',vid)
    rcode = nf_get_var_double(fid, vid, gridmap%frac_src)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)
    if ( any(gridmap%frac_src(:) < 0.0_r8 .or. gridmap%frac_src > (1.0_r8 + tol)) )then
       write(6,*) SubName//' ERROR: frac_src out of bounds'
       write(6,*) 'max = ', maxval(gridmap%frac_src), ' min = ', minval(gridmap%frac_src)
       call abort()
    end if

    rcode = nf_inq_varid(fid,'frac_b',vid)
    rcode = nf_get_var_double(fid, vid, gridmap%frac_dst)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)
    if ( any(gridmap%frac_dst(:) < 0.0_r8 .or. gridmap%frac_dst > (1.0_r8 + tol)) )then
       write(6,*) SubName//' ERROR: frac_dst out of bounds'
       write(6,*) 'max = ', maxval(gridmap%frac_dst), ' min = ', minval(gridmap%frac_dst)
       call abort()
    end if

    rcode = nf_inq_varid(fid,'xc_a',vid)
    rcode = nf_get_var_double(fid, vid, gridmap%xc_src)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)
    call convert_latlon(fid, 'xc_a', gridmap%xc_src)

    rcode = nf_inq_varid(fid,'yc_a',vid)
    rcode = nf_get_var_double(fid, vid, gridmap%yc_src)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)
    call convert_latlon(fid, 'yc_a', gridmap%yc_src)

    rcode = nf_inq_varid(fid,'xc_b',vid)
    rcode = nf_get_var_double(fid, vid, gridmap%xc_dst)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)
    call convert_latlon(fid, 'xc_b', gridmap%xc_dst)

    rcode = nf_inq_varid(fid,'yc_b',vid)
    rcode = nf_get_var_double(fid, vid, gridmap%yc_dst)
    if (rcode /= NF_NOERR) write(6,F00) nf_strerror(rcode)
    call convert_latlon(fid, 'yc_b', gridmap%yc_dst)

    rcode = nf_close(fid)

    gridmap%set = IsSet

  end subroutine gridmap_mapread

!==========================================================================

  !-----------------------------------------------------------------------
  subroutine for_test_create_gridmap(gridmap, na, nb, ns, &
       src_indx, dst_indx, wovr, &
       frac_src, frac_dst, area_src, area_dst, &
       xc_src, xc_dst, yc_src, yc_dst)
    !
    ! !DESCRIPTION:
    ! Creates a gridmap object directly from inputs
    !
    ! This is meant for testing
    !
    ! !ARGUMENTS:
    type(gridmap_type), intent(out) :: gridmap
    integer, intent(in) :: na
    integer, intent(in) :: nb
    integer, intent(in) :: ns
    integer, intent(in) :: src_indx(:)
    integer, intent(in) :: dst_indx(:)
    real(r8), intent(in) :: wovr(:)

    ! If not provided, mask and frac values are set to 1 everywhere
    real(r8), intent(in), optional :: frac_src(:)
    real(r8), intent(in), optional :: frac_dst(:)

    ! If not provided, area values are set to a constant value everywhere
    real(r8), intent(in), optional :: area_src(:)
    real(r8), intent(in), optional :: area_dst(:)

    ! If not provided, xc and yc values are set to 0 everywhere
    real(r8), intent(in), optional :: xc_src(:)
    real(r8), intent(in), optional :: xc_dst(:)
    real(r8), intent(in), optional :: yc_src(:)
    real(r8), intent(in), optional :: yc_dst(:)

    !
    ! !LOCAL VARIABLES:

    character(len=*), parameter :: subname = 'for_test_create_gridmap'
    !-----------------------------------------------------------------------

    ! ------------------------------------------------------------------------
    ! Error checking on sizes of arrays
    ! ------------------------------------------------------------------------
    call check_input_size('src_indx', size(src_indx), ns)
    call check_input_size('dst_indx', size(dst_indx), ns)
    call check_input_size('wovr', size(wovr), ns)

    if (present(frac_src)) then
       call check_input_size('frac_src', size(frac_src), na)
    end if
    if (present(area_src)) then
       call check_input_size('area_src', size(area_src), na)
    end if
    if (present(xc_src)) then
       call check_input_size('xc_src', size(xc_src), na)
    end if
    if (present(yc_src)) then
       call check_input_size('yc_src', size(yc_src), na)
    end if

    if (present(frac_dst)) then
       call check_input_size('frac_dst', size(frac_dst), nb)
    end if
    if (present(area_dst)) then
       call check_input_size('area_dst', size(area_dst), nb)
    end if
    if (present(xc_dst)) then
       call check_input_size('xc_dst', size(xc_dst), nb)
    end if
    if (present(yc_dst)) then
       call check_input_size('yc_dst', size(yc_dst), nb)
    end if

    ! ------------------------------------------------------------------------
    ! Create gridmap object
    ! ------------------------------------------------------------------------

    gridmap%na = na
    gridmap%nb = nb
    gridmap%ns = ns

    allocate(gridmap%src_indx(ns))
    gridmap%src_indx = src_indx
    allocate(gridmap%dst_indx(ns))
    gridmap%dst_indx = dst_indx
    allocate(gridmap%wovr(ns))
    gridmap%wovr = wovr

    allocate(gridmap%frac_src(na))
    call set_gridmap_var(gridmap%frac_src, 1._r8, frac_src)
    allocate(gridmap%frac_dst(nb))
    call set_gridmap_var(gridmap%frac_dst, 1._r8, frac_dst)

    allocate(gridmap%yc_src(na))
    call set_gridmap_var(gridmap%yc_src, 0._r8, yc_src)
    allocate(gridmap%yc_dst(nb))
    call set_gridmap_var(gridmap%yc_dst, 0._r8, yc_dst)
    allocate(gridmap%xc_src(na))
    call set_gridmap_var(gridmap%xc_src, 0._r8, xc_src)
    allocate(gridmap%xc_dst(nb))
    call set_gridmap_var(gridmap%xc_dst, 0._r8, xc_dst)
    allocate(gridmap%area_src(na))
    call set_gridmap_var(gridmap%area_src, 0._r8, area_src)
    allocate(gridmap%area_dst(nb))
    call set_gridmap_var(gridmap%area_dst, 0._r8, area_dst)

    gridmap%set = isSet

  contains
    subroutine check_input_size(varname, actual_size, expected_size)
      character(len=*), intent(in) :: varname
      integer, intent(in) :: actual_size
      integer, intent(in) :: expected_size

      if (actual_size /= expected_size) then
         write(6,*) subname, ' ERROR: ', trim(varname), ' wrong size: actual, expected = ', &
              actual_size, expected_size
         call abort()
      end if
    end subroutine check_input_size

  end subroutine for_test_create_gridmap

  subroutine set_gridmap_var_r8(var, default_val, input_val)
    ! Convenience subroutine to set a variable to an optional input or a default value
    real(r8), intent(out) :: var(:)
    real(r8), intent(in) :: default_val
    real(r8), intent(in), optional :: input_val(:)

    if (present(input_val)) then
       var = input_val
    else
       var = default_val
    end if
  end subroutine set_gridmap_var_r8

  subroutine set_gridmap_var_int(var, default_val, input_val)
    ! Convenience subroutine to set a variable to an optional input or a default value
    integer, intent(out) :: var(:)
    integer, intent(in) :: default_val
    integer, intent(in), optional :: input_val(:)

    if (present(input_val)) then
       var = input_val
    else
       var = default_val
    end if
  end subroutine set_gridmap_var_int

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_check
!
! !INTERFACE:
  subroutine gridmap_check(gridmap, mask_src, frac_dst, caller)
!
! !DESCRIPTION:
! Check validity of a gridmap
! Aborts if there are any errors
!
! !USES:
    use mkvarctl, only : mksrf_gridtype
    use mkvarpar, only : re
!
! !ARGUMENTS:
    implicit none
    type(gridmap_type) , intent(in) :: gridmap   ! mapping data
    real(r8), intent(in) :: mask_src(:)  ! input mask; could be declared integer but for the argument passed from subr. mktopostats
    real(r8), intent(in) :: frac_dst(:)  ! output fractions
    character(len=*)   , intent(in) :: caller    ! calling subroutine (used for error messages)
!
! !REVISION HISTORY:
!   Created by Bill Sacks
!
! !LOCAL VARIABLES:
    real(r8) :: sum_area_i        ! global sum of input area
    real(r8) :: sum_area_o        ! global sum of output area
    integer  :: ni,no,ns_i,ns_o   ! indices

    real(r8), parameter :: relerr = 0.00001        ! max error: sum overlap wts ne 1
    character(len=*), parameter :: subname = 'gridmap_check'
!EOP
!------------------------------------------------------------------------------

    ns_i = gridmap%na
    ns_o = gridmap%nb

    ! -----------------------------------------------------------------
    ! Error check prep
    ! Global sum of output area -- must multiply by fraction of
    ! output grid that is land as determined by input grid
    ! -----------------------------------------------------------------
    
    sum_area_i = 0.0_r8
    do ni = 1,ns_i
       sum_area_i = sum_area_i + gridmap%area_src(ni)*mask_src(ni)*re**2
    enddo

    sum_area_o = 0.
    do no = 1,ns_o
       sum_area_o = sum_area_o + gridmap%area_dst(no)*frac_dst(no)*re**2
    end do

    ! -----------------------------------------------------------------
    ! Error check1
    ! Compare global sum_area_i to global sum_area_o.
    ! -----------------------------------------------------------------

    if ( trim(mksrf_gridtype) == 'global' ) then
       if ( abs(sum_area_o/sum_area_i-1.) > relerr ) then
          write (6,*) subname//' ERROR from '//trim(caller)//': mapping areas not conserved'
          write (6,'(a30,e20.10)') 'global sum output field = ',sum_area_o
          write (6,'(a30,e20.10)') 'global sum input  field = ',sum_area_i
          call abort()
       end if
    end if

  end subroutine gridmap_check
    

!==========================================================================

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_areaave_scs
!
! !INTERFACE:
  subroutine gridmap_areaave_scs (gridmap, src_array, dst_array, nodata, src_wt, dst_wt, frac_dst)
!
! !DESCRIPTION:
! This subroutine does a simple area average, but multiplies by the ratio of the source over
! the destination weight. Sets to zero if destination weight is zero.
!
! The src_wt must be multiplied by tdomain%mask to maintain consistency with the
! incoming frac_dst.
!
! Called by subroutine mkpft.
!
! !ARGUMENTS:
    implicit none
    type(gridmap_type) , intent(in) :: gridmap   ! gridmap data
    real(r8), intent(in) :: src_array(:)
    real(r8), intent(out):: dst_array(:)
    real(r8), intent(in) :: nodata               ! value to apply where there are no input data
    real(r8), intent(in) :: src_wt(:)            ! Source weights
    real(r8), intent(in) :: dst_wt(:)            ! Destination weights
    real(r8), intent(in) :: frac_dst(:)          ! Output grid weights

!
! !REVISION HISTORY:
!   Created by Mariana Vertenstein, moditied by Sean Swenson
!
! !LOCAL VARIABLES:
    integer :: n,ns,ni,no
    real(r8):: wt,frac,swt,dwt
    real(r8), allocatable :: sum_weights(:)      ! sum of weights on the output grid
    character(*),parameter :: subName = '(gridmap_areaave_scs) '
!EOP
!------------------------------------------------------------------------------

    ! Error check inputs and initialize local variables

    if (size(frac_dst) /= size(dst_array)) then
       write(6,*) subname//' ERROR: incorrect size of frac_dst'
       write(6,*) 'size(frac_dst) = ', size(frac_dst)
       write(6,*) 'size(dst_array) = ', size(dst_array)
       call abort()
    end if

    call gridmap_checkifset( gridmap, subname )
    allocate(sum_weights(size(dst_array)))
    sum_weights = 0._r8
    dst_array = 0._r8

    do n = 1,gridmap%ns
       ni = gridmap%src_indx(n)
       no = gridmap%dst_indx(n)
       wt = gridmap%wovr(n)
       frac = frac_dst(no)
       swt = src_wt(ni)
       dwt = dst_wt(no)
       wt = wt * swt
       if(dwt > 0._r8) then 
          wt = wt / dwt
       else
          wt = 0._r8
       endif
       if (frac > 0.) then  
          dst_array(no) = dst_array(no) + wt * src_array(ni)/frac
          sum_weights(no) = sum_weights(no) + wt
       end if
    end do

    where (sum_weights == 0._r8)
       dst_array = nodata
    end where

    deallocate(sum_weights)

  end subroutine gridmap_areaave_scs

!==========================================================================

!==========================================================================

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_areaave_srcmask
!
! !INTERFACE:
  subroutine gridmap_areaave_srcmask (gridmap, src_array, dst_array, nodata, mask_src, frac_dst)
!
! !DESCRIPTION:
! This subroutine does an area average with the source mask
!
! !NOTES:
! We have generally moved to "nomask" mapping files. This means that mapping
! files now typically contain mask and frac equal to 1 everywhere. So now during
! remapping we apply the source masks found in the raw datasets and ignore the
! masks found in the mapping files. Exception: we continue to use a masked
! mapping file to regrid the 1-km topography.
!
! !ARGUMENTS:
     implicit none
    type(gridmap_type) , intent(in) :: gridmap   ! gridmap data
    real(r8), intent(in) :: src_array(:)
    real(r8), intent(out):: dst_array(:)
    real(r8), intent(in) :: nodata               ! value to apply where there are no input data
    integer, intent(in) :: mask_src(:)
    real(r8), intent(in) :: frac_dst(:)
!
! !REVISION HISTORY:
!   Created by Mariana Vertenstein
!
! !LOCAL VARIABLES:
    integer :: n,ns,ni,no
    real(r8):: wt
    character(*),parameter :: subName = '(gridmap_areaave_srcmask) '
!EOP
!------------------------------------------------------------------------------
    ! Error check inputs and initialize local variables

    ns = size(dst_array)
    if (size(frac_dst) /= ns) then
       write(6,*) subname//' ERROR: incorrect size of frac_dst'
       write(6,*) 'size(frac_dst) = ', size(frac_dst)
       write(6,*) 'size(dst_array) = ', ns
       call abort()
    end if
    if (size(mask_src) /= size(src_array)) then
       write(6,*) subname//' ERROR: incorrect size of mask_src'
       write(6,*) 'size(mask_src) = ', size(mask_src)
       write(6,*) 'size(src_array) = ', size(src_array)
       call abort()
    end if

    call gridmap_checkifset( gridmap, subname )

    dst_array = 0._r8
    do n = 1,gridmap%ns
       ni = gridmap%src_indx(n)
       no = gridmap%dst_indx(n)
       wt = gridmap%wovr(n)
       if (mask_src(ni) > 0) then 
          dst_array(no) = dst_array(no) + wt*mask_src(ni)*src_array(ni)/frac_dst(no)
       end if
    end do

    where (frac_dst == 0._r8)
       dst_array = nodata
    end where

  end subroutine gridmap_areaave_srcmask

!==========================================================================

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_areastddev
!
! !INTERFACE:
  subroutine gridmap_areastddev (gridmap, src_array, dst_array, nodata)
!
! !DESCRIPTION:
! Computes area-weighted standard deviation
!
! We use the definition of standard deviation that applies if you measure the full
! population (as opposed to the unbiased standard deviation that should be used when
! sampling a subset of the full population). (This is equivalent to using 1/N rather than
! 1/(N-1).) This makes sense if we assume that the underlying values are constant
! throughout each source grid cell -- in that case, we know the full population as long as
! we know the values in all source grid cells, which is generally the case.
!
! The formula is from <http://en.wikipedia.org/wiki/Weighted_mean#Weighted_sample_variance>
! (accessed 3-4-13). 
!
! !ARGUMENTS:
    implicit none
    type(gridmap_type) , intent(in) :: gridmap   ! gridmap data
    real(r8), intent(in) :: src_array(:)
    real(r8), intent(out):: dst_array(:)
    real(r8), intent(in) :: nodata               ! value to apply where there are no input data
!
! !REVISION HISTORY:
!   Created by Bill Sacks
!
! !LOCAL VARIABLES:
    integer :: n,ni,no
    integer :: ns_o                                ! number of output points
    real(r8):: wt                                  ! weight of overlap
    real(r8), allocatable :: weighted_means(:)     ! weighted mean on the output grid
    real(r8), allocatable :: sum_weights(:)        ! sum of weights on the output grid
    character(*),parameter :: subName = '(gridmap_areastddev) '
!EOP
!------------------------------------------------------------------------------
    call gridmap_checkifset( gridmap, subname )

    ns_o = size(dst_array)
    allocate(weighted_means(ns_o))

    ! Subr. gridmap_areaave_no_srcmask should NOT be used in general. We have
    ! kept it to support the rare raw data files for which we have masking on
    ! the mapping file and, therefore, we do not explicitly pass the src_mask
    ! as an argument. In general, users are advised to use subroutine
    ! gridmap_areaave_srcmask.
    call gridmap_areaave_no_srcmask(gridmap, src_array, weighted_means, nodata=0._r8)

    ! WJS (3-5-13): I believe that sum_weights should be the same as gridmap%frac_dst,
    ! but I'm not positive of this, so we compute it explicitly to be safe
    allocate(sum_weights(ns_o))
    sum_weights(:) = 0._r8
    dst_array(:)   = 0._r8
    do n = 1,gridmap%ns
       ni = gridmap%src_indx(n)
       no = gridmap%dst_indx(n)
       wt = gridmap%wovr(n)
       ! The following accumulates the numerator of the weighted sigma-squared
       dst_array(no) = dst_array(no) + wt * (src_array(ni) - weighted_means(no))**2
       sum_weights(no) = sum_weights(no) + wt
    end do

    do no = 1,ns_o
       if (sum_weights(no) > 0._r8) then
          dst_array(no) = sqrt(dst_array(no)/sum_weights(no))
       else
          dst_array(no) = nodata
       end if
    end do

    deallocate(weighted_means, sum_weights)

  end subroutine gridmap_areastddev

!==========================================================================

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_clean
!
! !INTERFACE:
  subroutine gridmap_clean(gridmap)
!
! !DESCRIPTION:
! This subroutine deallocates the gridmap type
!
! !ARGUMENTS:
    implicit none
    type(gridmap_type), intent(inout)       :: gridmap
!
! !REVISION HISTORY:
!   Created by Mariana Vertenstein
!
! !LOCAL VARIABLES:
    character(len=*), parameter :: subName = "gridmap_clean"
    integer ier    ! error flag
!EOP
!------------------------------------------------------------------------------
    if ( gridmap%set .eq. IsSet )then
       deallocate(gridmap%wovr    , &
                  gridmap%src_indx, &
                  gridmap%dst_indx, &
                  gridmap%area_src, &
                  gridmap%area_dst, &
                  gridmap%frac_src, &
                  gridmap%frac_dst, &
                  gridmap%xc_src,   &
                  gridmap%yc_src, stat=ier)
       if (ier /= 0) then
          write(6,*) SubName//' ERROR: deallocate gridmap'
          call abort()
       endif
    else
       write(6,*) SubName//' Warning: calling '//trim(subName)//' on unallocated gridmap'
    end if
    gridmap%set = "NOT-set"

  end subroutine gridmap_clean

!==========================================================================

  subroutine gridmap_checkifset( gridmap, subname )

    implicit none
    type(gridmap_type), intent(in) :: gridmap
    character(len=*),   intent(in) :: subname

    if ( gridmap%set .ne. IsSet )then
       write(6,*) SubName//' ERROR: gridmap NOT set yet, run gridmap_mapread first'
       call abort()
    end if
  end subroutine gridmap_checkifset

!==========================================================================

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_calc_frac_dst
!
! !INTERFACE:
  subroutine gridmap_calc_frac_dst(gridmap, mask_src, frac_dst)
!
! !DESCRIPTION:
! This subroutine calculates frac_dst
!
! !ARGUMENTS:
    implicit none
    type(gridmap_type) , intent(in) :: gridmap   ! gridmap data
    integer, intent(in) :: mask_src(:)
    real(r8), intent(out) :: frac_dst(:)
!
! !REVISION HISTORY:
!   Created by Sam Levis
!
! !LOCAL VARIABLES:
    integer :: n,ns,ni,no
    real(r8):: wt
    character(*),parameter :: subName = '(gridmap_calc_frac_dst) '
!EOP
!------------------------------------------------------------------------------
    call gridmap_checkifset( gridmap, subname )
    frac_dst(:) = 0._r8

    do n = 1,gridmap%ns
       ni = gridmap%src_indx(n)
       no = gridmap%dst_indx(n)
       wt = gridmap%wovr(n)
       if (mask_src(ni) > 0) then
          frac_dst(no) = frac_dst(no) + wt*mask_src(ni)
       end if
    end do

  end subroutine gridmap_calc_frac_dst

!==========================================================================

!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: gridmap_areaave_no_srcmask
!
! !INTERFACE:
  subroutine gridmap_areaave_no_srcmask (gridmap, src_array, dst_array, nodata)
!
! !DESCRIPTION:
! This subroutine should NOT be used in general. We have kept it to support the
! rare raw data files for which we have masking on the mapping file and,
! therefore, we do not explicitly pass the src_mask as an argument. In general,
! users are advised to use subroutine gridmap_areaave_srcmask.
!
! Perform simple area average without explicitly passing a src mask. The src
! mask may be implicit in gridmap%wovr.
!
! !ARGUMENTS:
    implicit none
    type(gridmap_type) , intent(in) :: gridmap   ! gridmap data
    real(r8), intent(in) :: src_array(:)
    real(r8), intent(out):: dst_array(:)
    real(r8), intent(in) :: nodata               ! value to apply where there are no input data
!
! !REVISION HISTORY:
!   Created by Mariana Vertenstein
!
! !LOCAL VARIABLES:
    integer :: n,ns,ni,no
    real(r8):: wt,frac
    real(r8), allocatable :: sum_weights(:)      ! sum of weights on the output grid
    character(*),parameter :: subName = '(gridmap_areaave_no_srcmask) '
!EOP
!------------------------------------------------------------------------------
    call gridmap_checkifset( gridmap, subname )
    allocate(sum_weights(size(dst_array)))
    sum_weights = 0._r8
    dst_array = 0._r8

    do n = 1,gridmap%ns
       ni = gridmap%src_indx(n)
       no = gridmap%dst_indx(n)
       wt = gridmap%wovr(n)
       frac = gridmap%frac_dst(no)
       if (frac > 0.) then  
          dst_array(no) = dst_array(no) + wt * src_array(ni)/frac
          sum_weights(no) = sum_weights(no) + wt
       end if
    end do

    where (sum_weights == 0._r8)
       dst_array = nodata
    end where

    deallocate(sum_weights)

  end subroutine gridmap_areaave_no_srcmask

end module mkgridmapMod


