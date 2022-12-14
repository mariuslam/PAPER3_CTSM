module mktopostatsMod

!-----------------------------------------------------------------------
!BOP
!
! !MODULE: mktopostatsMod
!
! !DESCRIPTION:
! make various topography statistics
!
! !REVISION HISTORY:
! Author: Bill Sacks
!
!-----------------------------------------------------------------------
!
! !USES:
  use shr_kind_mod, only : r8 => shr_kind_r8
  use shr_sys_mod , only : shr_sys_flush
  use mkdomainMod , only : domain_checksame

  implicit none

  private

! !PUBLIC MEMBER FUNCTIONS:
  public mktopostats            ! make topo stddev & mean slope
!
!EOP
!===============================================================
contains
!===============================================================

!-----------------------------------------------------------------------
!BOP
!
! !IROUTINE: mktopostats
!
! !INTERFACE:
subroutine mktopostats(ldomain, mapfname, datfname, ndiag, topo_stddev_o, slope_o, std_elev)
!
! !DESCRIPTION:
! make various topography statistics
!
! !USES:
  use mkdomainMod, only : domain_type, domain_clean, domain_read
  use mkgridmapMod
  use mkncdio
  use mkdiagnosticsMod, only : output_diagnostics_continuous, output_diagnostics_continuous_outonly
  use mkchecksMod, only : min_bad, max_bad
!
! !ARGUMENTS:
  
  implicit none
  type(domain_type) , intent(in) :: ldomain
  character(len=*)  , intent(in) :: mapfname          ! input mapping file name
  character(len=*)  , intent(in) :: datfname          ! input data file name
  integer           , intent(in) :: ndiag             ! unit number for diag out
  real(r8)          , intent(in) :: std_elev          ! standard deviation of elevation (m) to use when not using input file
  real(r8)          , intent(out):: topo_stddev_o(:)  ! output grid: standard deviation of elevation (m)
  real(r8)          , intent(out):: slope_o(:)        ! output grid: slope (degrees)
!
! !CALLED FROM:
! subroutine mksrfdat in module mksrfdatMod
!
! !REVISION HISTORY:
! Author: Bill Sacks
!
!
! !LOCAL VARIABLES:
!EOP
  type(gridmap_type)    :: tgridmap
  type(domain_type)     :: tdomain            ! local domain
  real(r8), allocatable :: data_i(:)          ! data on input grid
  integer  :: ncid,varid                      ! input netCDF id's
  integer  :: ier                             ! error status
  logical  :: bypass_reading                  ! If should bypass reading dataset and just use a global value
  
  real(r8), parameter :: min_valid_topo_stddev = 0._r8

  real(r8), parameter :: min_valid_slope = 0._r8
  real(r8), parameter :: max_valid_slope = 90._r8

  character(len=32) :: subname = 'mktopostats'
!-----------------------------------------------------------------------

  write (6,*) 'Attempting to make Topography statistics.....'
  if ( std_elev >= 0.0_r8 )then
     bypass_reading = .true.
     write (6,*) '    By pass the reading and just use global values'
  else
     bypass_reading = .false.
  end if
  call shr_sys_flush(6)

  ! -----------------------------------------------------------------
  ! Read domain and mapping information, check for consistency
  ! -----------------------------------------------------------------

  if ( .not. bypass_reading )then
     call domain_read(tdomain,datfname)
  
     call gridmap_mapread(tgridmap, mapfname )

     call gridmap_check( tgridmap, tgridmap%frac_src, tgridmap%frac_dst, subname )

     call domain_checksame( tdomain, ldomain, tgridmap )

     ! -----------------------------------------------------------------
     ! Open input file, allocate memory for input data
     ! -----------------------------------------------------------------

     write(6,*)'Open Topography file: ', trim(datfname)
     call check_ret(nf_open(datfname, 0, ncid), subname)

     allocate(data_i(tdomain%ns), stat=ier)
     if (ier/=0) call abort()

     ! -----------------------------------------------------------------
     ! Make topography standard deviation
     ! -----------------------------------------------------------------

     call check_ret(nf_inq_varid (ncid, 'ELEVATION', varid), subname)
     call check_ret(nf_get_var_double (ncid, varid, data_i), subname)
     call gridmap_areastddev(tgridmap, data_i, topo_stddev_o, nodata=0._r8)

     call output_diagnostics_continuous_outonly(topo_stddev_o, tgridmap, "Topo Std Dev", "m", ndiag)
  else
     write (6,*) '    Set std deviation of topography to ', std_elev
     topo_stddev_o = std_elev
  end if

  ! Check validity of output data
  if (min_bad(topo_stddev_o, min_valid_topo_stddev, 'topo_stddev')) then
     call abort()
  end if


  ! -----------------------------------------------------------------
  ! Regrid slope
  ! -----------------------------------------------------------------

  if ( .not. bypass_reading )then
     call check_ret(nf_inq_varid (ncid, 'SLOPE', varid), subname)
     call check_ret(nf_get_var_double (ncid, varid, data_i), subname)

     ! Subr. gridmap_areaave_no_srcmask should NOT be used in general. We have
     ! kept it to support the rare raw data files for which we have masking on
     ! the mapping file and, therefore, we do not explicitly pass the src_mask
     ! as an argument. In general, users are advised to use subroutine
     ! gridmap_areaave_srcmask.
     call gridmap_areaave_no_srcmask(tgridmap, data_i, slope_o, nodata=0._r8)

     call output_diagnostics_continuous(data_i, slope_o, tgridmap, "Slope", "degrees", ndiag, tdomain%mask, tgridmap%frac_dst)
  else
     write (6,*) '    Set slope of topography to ', 0.0_r8
     slope_o = 0.0_r8
  end if
  ! Check validity of output data
  if (min_bad(slope_o, min_valid_slope, 'slope') .or. &
      max_bad(slope_o, max_valid_slope, 'slope')) then
     call abort()
  end if


  ! -----------------------------------------------------------------
  ! Close files and deallocate dynamic memory
  ! -----------------------------------------------------------------

  if ( .not. bypass_reading )then
     call check_ret(nf_close(ncid), subname)
     call domain_clean(tdomain) 
     call gridmap_clean(tgridmap)
     deallocate (data_i)
  end if

  write (6,*) 'Successfully made Topography statistics'
  write (6,*)
  call shr_sys_flush(6)

end subroutine mktopostats


end module mktopostatsMod
