module FireDataBaseType

#include "shr_assert.h"

  !-----------------------------------------------------------------------
  ! !DESCRIPTION:
  ! module for handling of fire data
  !
  ! !USES:
  use shr_kind_mod    , only : r8 => shr_kind_r8, CL => shr_kind_CL
  use shr_strdata_mod , only : shr_strdata_type, shr_strdata_create, shr_strdata_print
  use shr_strdata_mod , only : shr_strdata_advance
  use shr_log_mod     , only : errMsg => shr_log_errMsg
  use clm_varctl      , only : iulog, inst_name
  use spmdMod         , only : masterproc, mpicom, comp_id
  use fileutils       , only : getavu, relavu
  use domainMod       , only : ldomain
  use abortutils      , only : endrun
  use decompMod       , only : bounds_type
  use FireMethodType  , only : fire_method_type
  use lnd_set_decomp_and_domain, only : gsmap_global
  use mct_mod
  !
  implicit none
  private
  !
  ! !PUBLIC TYPES:
  public :: fire_base_type

  !
  type, abstract, extends(fire_method_type) :: fire_base_type
    private
      ! !PRIVATE MEMBER DATA:

      real(r8), public, pointer :: forc_lnfm(:)    ! Lightning frequency
      real(r8), public, pointer :: forc_hdm(:)     ! Human population density
      
      real(r8), public, pointer :: gdp_lf_col(:)   ! col global real gdp data (k US$/capita)
      real(r8), public, pointer :: peatf_lf_col(:) ! col global peatland fraction data (0-1)
      integer , public, pointer :: abm_lf_col(:)   ! col global peak month of crop fire emissions

      type(shr_strdata_type) :: sdat_hdm    ! Human population density input data stream
      type(shr_strdata_type) :: sdat_lnfm   ! Lightning input data stream

    contains
      !
      ! !PUBLIC MEMBER FUNCTIONS:
      procedure, public :: FireInit => BaseFireInit     ! Initialization of Fire
      procedure, public :: BaseFireInit                 ! Initialization of Fire
      procedure(FireReadNML_interface), public, deferred :: FireReadNML       ! Read in namelist for Fire
      procedure, public :: FireInterp        ! Interpolate fire data
      procedure(need_lightning_and_popdens_interface), public, deferred :: &
           need_lightning_and_popdens ! Returns true if need lightning & popdens
      !
      ! !PRIVATE MEMBER FUNCTIONS:
      procedure, private :: hdm_init     ! position datasets for dynamic human population density
      procedure, private :: hdm_interp   ! interpolates between two years of human pop. density file data
      procedure, private :: lnfm_init    ! position datasets for Lightning
      procedure, private :: lnfm_interp  ! interpolates between two years of Lightning file data
      procedure, private :: surfdataread ! read fire related data from surface data set
  end type fire_base_type
  !-----------------------------------------------------------------------

  abstract interface
     !-----------------------------------------------------------------------
     function need_lightning_and_popdens_interface(this) result(need_lightning_and_popdens)
       !
       ! !DESCRIPTION:
       ! Returns true if need lightning and popdens, false otherwise
       !
       ! USES
       import :: fire_base_type
       !
       ! !ARGUMENTS:
       class(fire_base_type), intent(in) :: this
       logical :: need_lightning_and_popdens  ! function result
       !-----------------------------------------------------------------------
     end function need_lightning_and_popdens_interface
  end interface

  character(len=*), parameter, private :: sourcefile = &
       __FILE__

contains

  !-----------------------------------------------------------------------
  subroutine FireReadNML_interface( this, NLFilename )
    !
    ! !DESCRIPTION:
    ! Read the namelist for Fire
    !
    ! !USES:
    !
    ! !ARGUMENTS:
    class(fire_base_type) :: this
    character(len=*), intent(in) :: NLFilename ! Namelist filename
  end subroutine FireReadNML_interface

  !-----------------------------------------------------------------------
  subroutine BaseFireInit( this, bounds, NLFilename )
    !
    ! !DESCRIPTION:
    ! Initialize CN Fire module
    ! !USES:
    use shr_infnan_mod  , only : nan => shr_infnan_nan, assignment(=)
    !
    ! !ARGUMENTS:
    class(fire_base_type) :: this
    type(bounds_type), intent(in) :: bounds
    character(len=*),  intent(in) :: NLFilename
    !-----------------------------------------------------------------------

    if ( this%need_lightning_and_popdens() ) then
       ! Allocate lightning forcing data
       allocate( this%forc_lnfm(bounds%begg:bounds%endg) )
       this%forc_lnfm(bounds%begg:) = nan
       ! Allocate pop dens forcing data
       allocate( this%forc_hdm(bounds%begg:bounds%endg) )
       this%forc_hdm(bounds%begg:) = nan
       
       ! Allocate real gdp data
       allocate(this%gdp_lf_col(bounds%begc:bounds%endc))
       ! Allocate peatland fraction data
       allocate(this%peatf_lf_col(bounds%begc:bounds%endc))
       ! Allocates peak month of crop fire emissions
       allocate(this%abm_lf_col(bounds%begc:bounds%endc))
   

       call this%hdm_init(bounds, NLFilename)
       call this%hdm_interp(bounds)
       call this%lnfm_init(bounds, NLFilename)
       call this%lnfm_interp(bounds)
       call this%surfdataread(bounds)
    end if

  end subroutine BaseFireInit

  !-----------------------------------------------------------------------
  subroutine FireInterp(this,bounds)
    !
    ! !DESCRIPTION:
    ! Interpolate CN Fire datasets
    !
    ! !ARGUMENTS:
    class(fire_base_type) :: this
    type(bounds_type), intent(in) :: bounds
    !-----------------------------------------------------------------------

    if ( this%need_lightning_and_popdens() ) then
       call this%hdm_interp(bounds)
       call this%lnfm_interp(bounds)
    end if

  end subroutine FireInterp

  !-----------------------------------------------------------------------
  subroutine hdm_init( this, bounds, NLFilename )
   !
   ! !DESCRIPTION:
   ! Initialize data stream information for population density.
   !
   ! !USES:
   use clm_time_manager , only : get_calendar
   use ncdio_pio        , only : pio_subsystem
   use shr_pio_mod      , only : shr_pio_getiotype
   use clm_nlUtilsMod   , only : find_nlgroup_name
   use ndepStreamMod    , only : clm_domain_mct
   use histFileMod      , only : hist_addfld1d
   !
   ! !ARGUMENTS:
   implicit none
   class(fire_base_type)         :: this
   type(bounds_type), intent(in) :: bounds
   character(len=*),  intent(in) :: NLFilename   ! Namelist filename
   !
   ! !LOCAL VARIABLES:
   integer            :: stream_year_first_popdens   ! first year in pop. dens. stream to use
   integer            :: stream_year_last_popdens    ! last year in pop. dens. stream to use
   integer            :: model_year_align_popdens    ! align stream_year_first_hdm with
   integer            :: nu_nml                      ! unit for namelist file
   integer            :: nml_error                   ! namelist i/o error flag
   type(mct_ggrid)    :: dom_clm                     ! domain information
   character(len=CL)  :: stream_fldFileName_popdens  ! population density streams filename
   character(len=CL)  :: popdensmapalgo = 'bilinear' ! mapping alogrithm for population density
   character(len=CL)  :: popdens_tintalgo = 'nearest'! time interpolation alogrithm for population density
   character(len=CL)  :: stream_meshfile_popdens     ! not used
   character(*), parameter :: subName = "('hdmdyn_init')"
   character(*), parameter :: F00 = "('(hdmdyn_init) ',4a)"
   !-----------------------------------------------------------------------

   namelist /popd_streams/          &
        stream_year_first_popdens,  &
        stream_year_last_popdens,   &
        model_year_align_popdens,   &
        popdensmapalgo,             &
        stream_fldFileName_popdens, &
        stream_meshfile_popdens   , &
        popdens_tintalgo

   ! Default values for namelist
   stream_year_first_popdens  = 1       ! first year in stream to use
   stream_year_last_popdens   = 1       ! last  year in stream to use
   model_year_align_popdens   = 1       ! align stream_year_first_popdens with this model year
   stream_fldFileName_popdens = ' '

   ! Read popd_streams namelist
   if (masterproc) then
      nu_nml = getavu()
      open( nu_nml, file=trim(NLFilename), status='old', iostat=nml_error )
      call find_nlgroup_name(nu_nml, 'popd_streams', status=nml_error)
      if (nml_error == 0) then
         read(nu_nml, nml=popd_streams,iostat=nml_error)
         if (nml_error /= 0) then
            call endrun(msg='ERROR reading popd_streams namelist'//errMsg(sourcefile, __LINE__))
         end if
      end if
      close(nu_nml)
      call relavu( nu_nml )
   endif

   call shr_mpi_bcast(stream_year_first_popdens, mpicom)
   call shr_mpi_bcast(stream_year_last_popdens, mpicom)
   call shr_mpi_bcast(model_year_align_popdens, mpicom)
   call shr_mpi_bcast(stream_fldFileName_popdens, mpicom)
   call shr_mpi_bcast(popdens_tintalgo, mpicom)

   if (masterproc) then
      write(iulog,*) ' '
      write(iulog,*) 'popdens_streams settings:'
      write(iulog,*) '  stream_year_first_popdens  = ',stream_year_first_popdens
      write(iulog,*) '  stream_year_last_popdens   = ',stream_year_last_popdens
      write(iulog,*) '  model_year_align_popdens   = ',model_year_align_popdens
      write(iulog,*) '  stream_fldFileName_popdens = ',stream_fldFileName_popdens
      write(iulog,*) '  popdens_tintalgo           = ',popdens_tintalgo
      write(iulog,*) ' '
   endif

   call clm_domain_mct (bounds, dom_clm)

   call shr_strdata_create(this%sdat_hdm,name="clmhdm", &
        pio_subsystem=pio_subsystem,                    &
        pio_iotype=shr_pio_getiotype(inst_name),        &
        mpicom=mpicom, compid=comp_id,                  &
        gsmap=gsmap_global, ggrid=dom_clm,              &
        nxg=ldomain%ni, nyg=ldomain%nj,                 &
        yearFirst=stream_year_first_popdens,            &
        yearLast=stream_year_last_popdens,              &
        yearAlign=model_year_align_popdens,             &
        offset=0,                                       &
        domFilePath='',                                 &
        domFileName=trim(stream_fldFileName_popdens),   &
        domTvarName='time',                             &
        domXvarName='lon' ,                             &
        domYvarName='lat' ,                             &
        domAreaName='area',                             &
        domMaskName='mask',                             &
        filePath='',                                    &
        filename=(/trim(stream_fldFileName_popdens)/) , &
        fldListFile='hdm',                              &
        fldListModel='hdm',                             &
        fillalgo='none',                                &
        mapalgo=popdensmapalgo,                         &
        calendar=get_calendar(),                        &
        tintalgo=popdens_tintalgo,                      &
        taxmode='extend'                           )

   if (masterproc) then
      call shr_strdata_print(this%sdat_hdm,'population density data')
   endif

   ! Add history fields
   call hist_addfld1d (fname='HDM', units='counts/km^2',      &
         avgflag='A', long_name='human population density',   &
         ptr_lnd=this%forc_hdm, default='inactive')

  end subroutine hdm_init

  !-----------------------------------------------------------------------
  subroutine hdm_interp( this, bounds)
  !
  ! !DESCRIPTION:
  ! Interpolate data stream information for population density.
  !
  ! !USES:
  use clm_time_manager, only : get_curr_date
  !
  ! !ARGUMENTS:
  class(fire_base_type)       :: this
  type(bounds_type), intent(in) :: bounds
  !
  ! !LOCAL VARIABLES:
  integer :: g, ig
  integer :: year    ! year (0, ...) for nstep+1
  integer :: mon     ! month (1, ..., 12) for nstep+1
  integer :: day     ! day of month (1, ..., 31) for nstep+1
  integer :: sec     ! seconds into current date for nstep+1
  integer :: mcdate  ! Current model date (yyyymmdd)
  !-----------------------------------------------------------------------

   call get_curr_date(year, mon, day, sec)
   mcdate = year*10000 + mon*100 + day

   call shr_strdata_advance(this%sdat_hdm, mcdate, sec, mpicom, 'hdmdyn')

   ig = 0
   do g = bounds%begg,bounds%endg
      ig = ig+1
      this%forc_hdm(g) = this%sdat_hdm%avs(1)%rAttr(1,ig)
   end do

  end subroutine hdm_interp

  !-----------------------------------------------------------------------
  subroutine lnfm_init( this, bounds, NLFilename )
  !
  ! !DESCRIPTION:
  !
  ! Initialize data stream information for Lightning.
  !
  ! !USES:
  use clm_time_manager , only : get_calendar
  use ncdio_pio        , only : pio_subsystem
  use shr_pio_mod      , only : shr_pio_getiotype
  use clm_nlUtilsMod   , only : find_nlgroup_name
  use ndepStreamMod    , only : clm_domain_mct
  use histFileMod      , only : hist_addfld1d
  !
  ! !ARGUMENTS:
  implicit none
  class(fire_base_type)       :: this
  type(bounds_type), intent(in) :: bounds
  character(len=*),  intent(in) :: NLFilename
  !
  ! !LOCAL VARIABLES:
  integer            :: stream_year_first_lightng  ! first year in Lightning stream to use
  integer            :: stream_year_last_lightng   ! last year in Lightning stream to use
  integer            :: model_year_align_lightng   ! align stream_year_first_lnfm with
  integer            :: nu_nml                     ! unit for namelist file
  integer            :: nml_error                  ! namelist i/o error flag
  type(mct_ggrid)    :: dom_clm                    ! domain information
  character(len=CL)  :: stream_fldFileName_lightng ! lightning stream filename to read
  character(len=CL)  :: lightng_tintalgo = 'linear'! time interpolation alogrithm
  character(len=CL)  :: lightngmapalgo = 'bilinear'! Mapping alogrithm
  character(*), parameter :: subName = "('lnfmdyn_init')"
  character(*), parameter :: F00 = "('(lnfmdyn_init) ',4a)"
  !-----------------------------------------------------------------------

   namelist /light_streams/         &
        stream_year_first_lightng,  &
        stream_year_last_lightng,   &
        model_year_align_lightng,   &
        lightngmapalgo,             &
        stream_fldFileName_lightng, &
        lightng_tintalgo

   ! Default values for namelist
    stream_year_first_lightng  = 1      ! first year in stream to use
    stream_year_last_lightng   = 1      ! last  year in stream to use
    model_year_align_lightng   = 1      ! align stream_year_first_lnfm with this model year
    stream_fldFileName_lightng = ' '

   ! Read light_streams namelist
   if (masterproc) then
      nu_nml = getavu()
      open( nu_nml, file=trim(NLFilename), status='old', iostat=nml_error )
      call find_nlgroup_name(nu_nml, 'light_streams', status=nml_error)
      if (nml_error == 0) then
         read(nu_nml, nml=light_streams,iostat=nml_error)
         if (nml_error /= 0) then
            call endrun(msg='ERROR reading light_streams namelist'//errMsg(sourcefile, __LINE__))
         end if
      end if
      close(nu_nml)
      call relavu( nu_nml )
   endif

   call shr_mpi_bcast(stream_year_first_lightng, mpicom)
   call shr_mpi_bcast(stream_year_last_lightng, mpicom)
   call shr_mpi_bcast(model_year_align_lightng, mpicom)
   call shr_mpi_bcast(stream_fldFileName_lightng, mpicom)
   call shr_mpi_bcast(lightng_tintalgo, mpicom)

   if (masterproc) then
      write(iulog,*) ' '
      write(iulog,*) 'light_stream settings:'
      write(iulog,*) '  stream_year_first_lightng  = ',stream_year_first_lightng
      write(iulog,*) '  stream_year_last_lightng   = ',stream_year_last_lightng
      write(iulog,*) '  model_year_align_lightng   = ',model_year_align_lightng
      write(iulog,*) '  stream_fldFileName_lightng = ',stream_fldFileName_lightng
      write(iulog,*) '  lightng_tintalgo           = ',lightng_tintalgo
      write(iulog,*) ' '
   endif

   call clm_domain_mct (bounds, dom_clm)

   call shr_strdata_create(this%sdat_lnfm,name="clmlnfm", &
        pio_subsystem=pio_subsystem,                      &
        pio_iotype=shr_pio_getiotype(inst_name),          &
        mpicom=mpicom, compid=comp_id,                    &
        gsmap=gsmap_global, ggrid=dom_clm,                &
        nxg=ldomain%ni, nyg=ldomain%nj,                   &
        yearFirst=stream_year_first_lightng,              &
        yearLast=stream_year_last_lightng,                &
        yearAlign=model_year_align_lightng,               &
        offset=0,                                         &
        domFilePath='',                                   &
        domFileName=trim(stream_fldFileName_lightng),     &
        domTvarName='time',                               &
        domXvarName='lon' ,                               &
        domYvarName='lat' ,                               &
        domAreaName='area',                               &
        domMaskName='mask',                               &
        filePath='',                                      &
        filename=(/trim(stream_fldFileName_lightng)/),    &
        fldListFile='lnfm',                               &
        fldListModel='lnfm',                              &
        fillalgo='none',                                  &
        tintalgo=lightng_tintalgo,                        &
        mapalgo=lightngmapalgo,                           &
        calendar=get_calendar(),                          &
        taxmode='cycle'                            )

   if (masterproc) then
      call shr_strdata_print(this%sdat_lnfm,'Lightning data')
   endif

   ! Add history fields
   call hist_addfld1d (fname='LNFM', units='counts/km^2/hr',  &
         avgflag='A', long_name='Lightning frequency',        &
         ptr_lnd=this%forc_lnfm, default='inactive')

  end subroutine lnfm_init

  !-----------------------------------------------------------------------
  subroutine lnfm_interp(this, bounds )
  !
  ! !DESCRIPTION:
  ! Interpolate data stream information for Lightning.
  !
  ! !USES:
  use clm_time_manager, only : get_curr_date
  !
  ! !ARGUMENTS:
  class(fire_base_type)       :: this
  type(bounds_type), intent(in) :: bounds
  !
  ! !LOCAL VARIABLES:
  integer :: g, ig
  integer :: year    ! year (0, ...) for nstep+1
  integer :: mon     ! month (1, ..., 12) for nstep+1
  integer :: day     ! day of month (1, ..., 31) for nstep+1
  integer :: sec     ! seconds into current date for nstep+1
  integer :: mcdate  ! Current model date (yyyymmdd)
  !-----------------------------------------------------------------------

   call get_curr_date(year, mon, day, sec)
   mcdate = year*10000 + mon*100 + day

   call shr_strdata_advance(this%sdat_lnfm, mcdate, sec, mpicom, 'lnfmdyn')

   ig = 0
   do g = bounds%begg,bounds%endg
      ig = ig+1
      this%forc_lnfm(g) = this%sdat_lnfm%avs(1)%rAttr(1,ig)
   end do

  end subroutine lnfm_interp

  !-----------------------------------------------------------------------
  subroutine surfdataread(this, bounds)
  !
  ! !DESCRIPTION:
  ! Read surface data set to populate relevant fire-related variables
  !
  ! !USES:
  use spmdMod    , only : masterproc
  use clm_varctl , only : nsrest, nsrStartup, fsurdat
  use clm_varcon , only : grlnd
  use ColumnType , only : col
  use fileutils  , only : getfil
  use ncdio_pio
  !
  ! !ARGUMENTS:
  class(fire_base_type) :: this
  type(bounds_type), intent(in) :: bounds
  !
  ! !LOCAL VARIABLES:
  integer               :: g,c       ! indices
  type(file_desc_t)     :: ncid      ! netcdf id
  logical               :: readvar   ! true => variable is on initial dataset
  character(len=256)    :: locfn     ! local filename
  real(r8), pointer     :: gdp(:)    ! global gdp data (needs to be a pointer for use in ncdio)
  real(r8), pointer     :: peatf(:)  ! global peatf data (needs to be a pointer for use in ncdio)
  integer,  pointer     :: abm(:)    ! global abm data (needs to be a pointer for use in ncdio)
  !-----------------------------------------------------------------------

   ! --------------------------------------------------------------------
   ! Open surface dataset
   ! --------------------------------------------------------------------

   call getfil (fsurdat, locfn, 0)
   call ncd_pio_openfile (ncid, locfn, 0)

   ! --------------------------------------------------------------------
   ! Read in GDP data
   ! --------------------------------------------------------------------

   allocate(gdp(bounds%begg:bounds%endg))
   call ncd_io(ncid=ncid, varname='gdp', flag='read', data=gdp, dim1name=grlnd, readvar=readvar)
   if (.not. readvar) then
      call endrun(msg=' ERROR: gdp NOT on surfdata file'//errMsg(sourcefile, __LINE__))
   end if
   do c = bounds%begc, bounds%endc
      g = col%gridcell(c)
      this%gdp_lf_col(c) = gdp(g)
   end do
   deallocate(gdp)

   ! --------------------------------------------------------------------
   ! Read in peatf data
   ! --------------------------------------------------------------------

   allocate(peatf(bounds%begg:bounds%endg))
   call ncd_io(ncid=ncid, varname='peatf', flag='read', data=peatf, dim1name=grlnd, readvar=readvar)
   if (.not. readvar) then
      call endrun(msg=' ERROR: peatf NOT on surfdata file'//errMsg(sourcefile, __LINE__))
   end if
   do c = bounds%begc, bounds%endc
      g = col%gridcell(c)
      this%peatf_lf_col(c) = peatf(g)
   end do
   deallocate(peatf)

   ! --------------------------------------------------------------------
   ! Read in ABM data
   ! --------------------------------------------------------------------

   allocate(abm(bounds%begg:bounds%endg))
   call ncd_io(ncid=ncid, varname='abm', flag='read', data=abm, dim1name=grlnd, readvar=readvar)
   if (.not. readvar) then
      call endrun(msg=' ERROR: abm NOT on surfdata file'//errMsg(sourcefile, __LINE__))
   end if
   do c = bounds%begc, bounds%endc
      g = col%gridcell(c)
      this%abm_lf_col(c) = abm(g)
   end do
   deallocate(abm)

   ! Close file

   call ncd_pio_closefile(ncid)

   if (masterproc) then
      write(iulog,*) 'Successfully read fmax, soil color, sand and clay boundary data'
      write(iulog,*)
   endif
   
  end subroutine surfdataread
  
  
end module FireDataBaseType
