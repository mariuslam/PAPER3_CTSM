module lnd_comp_mct

  !---------------------------------------------------------------------------
  ! !DESCRIPTION:
  !  Interface of the active land model component of CESM the CLM (Community Land Model)
  !  with the main CESM driver. This is a thin interface taking CESM driver information
  !  in MCT (Model Coupling Toolkit) format and converting it to use by CLM.
  !
  ! !uses:
  use shr_kind_mod     , only : r8 => shr_kind_r8
  use shr_sys_mod      , only : shr_sys_flush
  use shr_log_mod      , only : errMsg => shr_log_errMsg
  use mct_mod          , only : mct_avect, mct_gsmap, mct_gGrid
  use decompmod        , only : bounds_type
  use lnd_import_export, only : lnd_import, lnd_export
  !
  ! !public member functions:
  implicit none
  private                     ! by default make data private
  !
  ! !public member functions:
  public :: lnd_init_mct      ! clm initialization
  public :: lnd_run_mct       ! clm run phase
  public :: lnd_final_mct     ! clm finalization/cleanup
  !
  ! !private member functions:
  private :: lnd_domain_mct    ! set the land model domain information
  private :: lnd_handle_resume ! handle pause/resume signals from the coupler

  character(len=*), parameter, private :: sourcefile = &
       __FILE__

!====================================================================================
contains
!====================================================================================

  subroutine lnd_init_mct( EClock, cdata_l, x2l_l, l2x_l, NLFilename )
    !
    ! !DESCRIPTION:
    ! Initialize land surface model and obtain relevant atmospheric model arrays
    ! back from (i.e. albedos, surface temperature and snow cover over land).
    !
    ! !USES:
    use shr_kind_mod     , only : shr_kind_cl
    use abortutils       , only : endrun
    use clm_time_manager , only : get_nstep, set_timemgr_init
    use clm_initializeMod, only : initialize1, initialize2
    use clm_instMod      , only : water_inst, lnd2atm_inst, lnd2glc_inst
    use clm_varctl       , only : finidat, single_column, clm_varctl_set, iulog
    use clm_varctl       , only : inst_index, inst_suffix, inst_name
    use clm_varorb       , only : eccen, obliqr, lambm0, mvelpp
    use controlMod       , only : control_setNL
    use decompMod        , only : get_proc_bounds
    use domainMod        , only : ldomain
    use shr_file_mod     , only : shr_file_setLogUnit, shr_file_setLogLevel
    use shr_file_mod     , only : shr_file_getLogUnit, shr_file_getLogLevel
    use shr_file_mod     , only : shr_file_getUnit, shr_file_setIO
    use seq_cdata_mod    , only : seq_cdata, seq_cdata_setptrs
    use seq_timemgr_mod  , only : seq_timemgr_EClockGetData
    use seq_infodata_mod , only : seq_infodata_type, seq_infodata_GetData, seq_infodata_PutData, &
                                  seq_infodata_start_type_start, seq_infodata_start_type_cont,   &
                                  seq_infodata_start_type_brnch
    use seq_comm_mct     , only : seq_comm_suffix, seq_comm_inst, seq_comm_name
    use seq_flds_mod     , only : seq_flds_x2l_fields, seq_flds_l2x_fields
    use spmdMod          , only : masterproc, spmd_init
    use clm_varctl       , only : nsrStartup, nsrContinue, nsrBranch
    use clm_cpl_indices  , only : clm_cpl_indices_set
    use mct_mod          , only : mct_aVect_init, mct_aVect_zero, mct_gsMap, mct_gsMap_init
    use decompMod        , only : gindex_global
    use lnd_set_decomp_and_domain, only : lnd_set_decomp_and_domain_from_surfrd, gsmap_global
    use ESMF
    !
    ! !ARGUMENTS:
    type(ESMF_Clock),           intent(inout) :: EClock           ! Input synchronization clock
    type(seq_cdata),            intent(inout) :: cdata_l          ! Input land-model driver data
    type(mct_aVect),            intent(inout) :: x2l_l, l2x_l     ! land model import and export states
    character(len=*), optional, intent(in)    :: NLFilename       ! Namelist filename to read
    !
    ! !LOCAL VARIABLES:
    integer                          :: LNDID        ! Land identifyer
    integer                          :: mpicom_lnd   ! MPI communicator
    type(mct_gsMap),         pointer :: GSMap_lnd    ! Land model MCT GS map
    type(mct_gGrid),         pointer :: dom_l        ! Land model domain
    type(seq_infodata_type), pointer :: infodata     ! CESM driver level info data
    integer  :: lsize                                ! size of attribute vector
    integer  :: gsize                                ! global size 
    integer  :: g,i,j                                ! indices
    integer  :: dtime_sync                           ! coupling time-step from the input synchronization clock
    logical  :: exists                               ! true if file exists
    logical  :: atm_aero                             ! Flag if aerosol data sent from atm model
    real(r8) :: scmlat                               ! single-column latitude
    real(r8) :: scmlon                               ! single-column longitude
    character(len=SHR_KIND_CL) :: caseid             ! case identifier name
    character(len=SHR_KIND_CL) :: ctitle             ! case description title
    character(len=SHR_KIND_CL) :: starttype          ! start-type (startup, continue, branch, hybrid)
    character(len=SHR_KIND_CL) :: calendar           ! calendar type name
    character(len=SHR_KIND_CL) :: hostname           ! hostname of machine running on
    character(len=SHR_KIND_CL) :: version            ! Model version
    character(len=SHR_KIND_CL) :: username           ! user running the model
    integer :: nsrest                                ! clm restart type
    integer :: ref_ymd                               ! reference date (YYYYMMDD)
    integer :: ref_tod                               ! reference time of day (sec)
    integer :: start_ymd                             ! start date (YYYYMMDD)
    integer :: start_tod                             ! start time of day (sec)
    logical :: brnch_retain_casename                 ! flag if should retain the case name on a branch start type
    integer :: lbnum                                 ! input to memory diagnostic
    integer :: shrlogunit,shrloglev                  ! old values for log unit and log level
    type(bounds_type) :: bounds                      ! bounds
    logical :: noland
    integer :: ni,nj
    real(r8)         , parameter :: rundef = -9999999._r8
    character(len=32), parameter :: sub = 'lnd_init_mct'
    character(len=*),  parameter :: format = "('("//trim(sub)//") :',A)"
    !-----------------------------------------------------------------------

    ! Set cdata data
    call seq_cdata_setptrs(cdata_l, ID=LNDID, mpicom=mpicom_lnd, &
         gsMap=GSMap_lnd, dom=dom_l, infodata=infodata)

    ! Determine attriute vector indices
    call clm_cpl_indices_set()

    ! Initialize clm MPI communicator
    call spmd_init( mpicom_lnd, LNDID )

#if (defined _MEMTRACE)
    if(masterproc) then
       lbnum=1
       call memmon_dump_fort('memmon.out','lnd_init_mct:start::',lbnum)
    endif
#endif

    inst_name   = seq_comm_name(LNDID)
    inst_index  = seq_comm_inst(LNDID)
    inst_suffix = seq_comm_suffix(LNDID)
    ! Initialize io log unit

    call shr_file_getLogUnit (shrlogunit)
    if (masterproc) then
       inquire(file='lnd_modelio.nml'//trim(inst_suffix),exist=exists)
       if (exists) then
          iulog = shr_file_getUnit()
          call shr_file_setIO('lnd_modelio.nml'//trim(inst_suffix),iulog)
       end if
       write(iulog,format) "CLM land model initialization"
    else
       iulog = shrlogunit
    end if

    call shr_file_getLogLevel(shrloglev)
    call shr_file_setLogUnit (iulog)

    ! Use infodata to set orbital values
    call seq_infodata_GetData( infodata, orb_eccen=eccen, orb_mvelpp=mvelpp, &
         orb_lambm0=lambm0, orb_obliqr=obliqr )

    ! Consistency check on namelist filename
    call control_setNL("lnd_in"//trim(inst_suffix))

    ! Initialize clm
    ! initialize1 reads namelists
    ! decomp and domain are set in lnd_set_decomp_and_domain_from_surfrd
    ! initialize2 performs the rest of initialization
    call seq_timemgr_EClockGetData(EClock,                               &
                                   start_ymd=start_ymd,                  &
                                   start_tod=start_tod, ref_ymd=ref_ymd, &
                                   ref_tod=ref_tod, &
                                   calendar=calendar, &
                                   dtime=dtime_sync)
    if (masterproc) then
       write(iulog,*)'dtime = ',dtime_sync
    end if
    call seq_infodata_GetData(infodata, case_name=caseid,    &
                              case_desc=ctitle, single_column=single_column,    &
                              scmlat=scmlat, scmlon=scmlon,                     &
                              brnch_retain_casename=brnch_retain_casename,      &
                              start_type=starttype, model_version=version,      &
                              hostname=hostname, username=username )

    ! Single Column
    if ( single_column .and. (scmlat == rundef  .or. scmlon == rundef ) ) then
       call endrun(msg=' ERROR:: single column mode on -- but scmlat and scmlon are NOT set'//&
            errMsg(sourcefile, __LINE__))
    end if

    ! Note that we assume that CTSM's internal dtime matches the coupling time step.
    ! i.e., we currently do NOT allow sub-cycling within a coupling time step.
    call set_timemgr_init( calendar_in=calendar, start_ymd_in=start_ymd, start_tod_in=start_tod, &
         ref_ymd_in=ref_ymd, ref_tod_in=ref_tod, dtime_in=dtime_sync)

    if (     trim(starttype) == trim(seq_infodata_start_type_start)) then
       nsrest = nsrStartup
    else if (trim(starttype) == trim(seq_infodata_start_type_cont) ) then
       nsrest = nsrContinue
    else if (trim(starttype) == trim(seq_infodata_start_type_brnch)) then
       nsrest = nsrBranch
    else
       call endrun( sub//' ERROR: unknown starttype' )
    end if

    ! set default values for run control variables
    call clm_varctl_set(caseid_in=caseid, ctitle_in=ctitle,                     &
                        brnch_retain_casename_in=brnch_retain_casename,         &
                        single_column_in=single_column, scmlat_in=scmlat,       &
                        scmlon_in=scmlon, nsrest_in=nsrest, version_in=version, &
                        hostname_in=hostname, username_in=username)

    ! Read namelists
    call initialize1(dtime=dtime_sync)

    ! Initialize decomposition and domain (ldomain) type
    call lnd_set_decomp_and_domain_from_surfrd(noland, ni, nj)

    ! If no land then exit out of initialization
    if ( noland ) then

       call seq_infodata_PutData( infodata, lnd_present   =.false.)
       call seq_infodata_PutData( infodata, lnd_prognostic=.false.)

    else

       ! Determine if aerosol and dust deposition come from atmosphere component
       call seq_infodata_GetData(infodata, atm_aero=atm_aero )
       if ( .not. atm_aero )then
          call endrun( sub//' ERROR: atmosphere model MUST send aerosols to CLM' )
       end if

       ! Initialize clm gsMap, clm domain and clm attribute vectors
       call get_proc_bounds( bounds )
       lsize = bounds%endg - bounds%begg + 1
       gsize = ldomain%ni * ldomain%nj
       call mct_gsMap_init( gsMap_lnd, gindex_global, mpicom_lnd, LNDID, lsize, gsize )
       gsmap_global => gsmap_lnd ! module variable in lnd_set_decomp_and_domain
       call lnd_domain_mct( bounds, lsize, gsMap_lnd, dom_l )
       call mct_aVect_init(x2l_l, rList=seq_flds_x2l_fields, lsize=lsize)
       call mct_aVect_zero(x2l_l)
       call mct_aVect_init(l2x_l, rList=seq_flds_l2x_fields, lsize=lsize)
       call mct_aVect_zero(l2x_l)

       ! Finish initializing clm
       call initialize2(ni,nj)

       ! Create land export state
       call lnd_export(bounds, water_inst%waterlnd2atmbulk_inst, lnd2atm_inst, lnd2glc_inst, l2x_l%rattr)

       ! Fill in infodata settings
       call seq_infodata_PutData(infodata, lnd_prognostic=.true.)
       call seq_infodata_PutData(infodata, lnd_nx=ldomain%ni, lnd_ny=ldomain%nj)
       call lnd_handle_resume( cdata_l )

       ! Reset shr logging to original values
       call shr_file_setLogUnit (shrlogunit)
       call shr_file_setLogLevel(shrloglev)

#if (defined _MEMTRACE)
       if(masterproc) then
          write(iulog,*) TRIM(Sub) // ':end::'
          lbnum=1
          call memmon_dump_fort('memmon.out','lnd_int_mct:end::',lbnum)
          call memmon_reset_addr()
       endif
#endif
    end if

  end subroutine lnd_init_mct

  !====================================================================================
  subroutine lnd_run_mct(EClock, cdata_l, x2l_l, l2x_l)
    !
    ! !DESCRIPTION:
    ! Run clm model
    !
    ! !USES:
    use shr_kind_mod    ,  only : r8 => shr_kind_r8
    use clm_instMod     ,  only : water_inst, lnd2atm_inst, atm2lnd_inst, lnd2glc_inst, glc2lnd_inst
    use clm_driver      ,  only : clm_drv
    use clm_time_manager,  only : get_curr_date, get_nstep, get_curr_calday, get_step_size
    use clm_time_manager,  only : advance_timestep, update_rad_dtime
    use decompMod       ,  only : get_proc_bounds
    use abortutils      ,  only : endrun
    use clm_varctl      ,  only : iulog
    use clm_varorb      ,  only : eccen, obliqr, lambm0, mvelpp
    use shr_file_mod    ,  only : shr_file_setLogUnit, shr_file_setLogLevel
    use shr_file_mod    ,  only : shr_file_getLogUnit, shr_file_getLogLevel
    use seq_cdata_mod   ,  only : seq_cdata, seq_cdata_setptrs
    use seq_timemgr_mod ,  only : seq_timemgr_EClockGetData, seq_timemgr_StopAlarmIsOn
    use seq_timemgr_mod ,  only : seq_timemgr_RestartAlarmIsOn, seq_timemgr_EClockDateInSync
    use seq_infodata_mod,  only : seq_infodata_type, seq_infodata_GetData
    use spmdMod         ,  only : masterproc, mpicom
    use perf_mod        ,  only : t_startf, t_stopf, t_barrierf
    use shr_orb_mod     ,  only : shr_orb_decl
    use ESMF
    !
    ! !ARGUMENTS:
    type(ESMF_Clock) , intent(inout) :: EClock    ! Input synchronization clock from driver
    type(seq_cdata)  , intent(inout) :: cdata_l   ! Input driver data for land model
    type(mct_aVect)  , intent(inout) :: x2l_l     ! Import state to land model
    type(mct_aVect)  , intent(inout) :: l2x_l     ! Export state from land model
    !
    ! !LOCAL VARIABLES:
    integer      :: ymd_sync             ! Sync date (YYYYMMDD)
    integer      :: yr_sync              ! Sync current year
    integer      :: mon_sync             ! Sync current month
    integer      :: day_sync             ! Sync current day
    integer      :: tod_sync             ! Sync current time of day (sec)
    integer      :: ymd                  ! CLM current date (YYYYMMDD)
    integer      :: yr                   ! CLM current year
    integer      :: mon                  ! CLM current month
    integer      :: day                  ! CLM current day
    integer      :: tod                  ! CLM current time of day (sec)
    integer      :: dtime                ! time step increment (sec)
    integer      :: nstep                ! time step index
    logical      :: rstwr_sync           ! .true. ==> write restart file before returning
    logical      :: rstwr                ! .true. ==> write restart file before returning
    logical      :: nlend_sync           ! Flag signaling last time-step
    logical      :: nlend                ! .true. ==> last time-step
    logical      :: dosend               ! true => send data back to driver
    logical      :: doalb                ! .true. ==> do albedo calculation on this time step
    logical      :: rof_prognostic       ! .true. => running with a prognostic ROF model
    logical      :: glc_present          ! .true. => running with a non-stub GLC model
    real(r8)     :: nextsw_cday          ! calday from clock of next radiation computation
    real(r8)     :: caldayp1             ! clm calday plus dtime offset
    integer      :: shrlogunit,shrloglev ! old values for share log unit and log level
    integer      :: lbnum                ! input to memory diagnostic
    integer      :: g,i,lsize            ! counters
    real(r8)     :: calday               ! calendar day for nstep
    real(r8)     :: declin               ! solar declination angle in radians for nstep
    real(r8)     :: declinp1             ! solar declination angle in radians for nstep+1
    real(r8)     :: eccf                 ! earth orbit eccentricity factor
    real(r8)     :: recip                ! reciprical
    logical,save :: first_call = .true.  ! first call work
    type(seq_infodata_type),pointer :: infodata             ! CESM information from the driver
    type(mct_gGrid),        pointer :: dom_l                ! Land model domain data
    type(bounds_type)               :: bounds               ! bounds
    character(len=32)               :: rdate                ! date char string for restart file names
    character(len=32), parameter    :: sub = "lnd_run_mct"
    !---------------------------------------------------------------------------

    ! Determine processor bounds

    call get_proc_bounds(bounds)

#if (defined _MEMTRACE)
    if(masterproc) then
       lbnum=1
       call memmon_dump_fort('memmon.out','lnd_run_mct:start::',lbnum)
    endif
#endif

    ! Reset shr logging to my log file
    call shr_file_getLogUnit (shrlogunit)
    call shr_file_getLogLevel(shrloglev)
    call shr_file_setLogUnit (iulog)

    ! Determine time of next atmospheric shortwave calculation
    call seq_cdata_setptrs(cdata_l, infodata=infodata, dom=dom_l)
    call seq_timemgr_EClockGetData(EClock, &
         curr_ymd=ymd, curr_tod=tod_sync,  &
         curr_yr=yr_sync, curr_mon=mon_sync, curr_day=day_sync)
    call seq_infodata_GetData(infodata, nextsw_cday=nextsw_cday )

    dtime = get_step_size()

    ! Handle pause/resume signals from coupler
    call lnd_handle_resume( cdata_l )

    write(rdate,'(i4.4,"-",i2.2,"-",i2.2,"-",i5.5)') yr_sync,mon_sync,day_sync,tod_sync
    nlend_sync = seq_timemgr_StopAlarmIsOn( EClock )
    rstwr_sync = seq_timemgr_RestartAlarmIsOn( EClock )

    ! Determine if we're running with a prognostic ROF model, and if we're running with a
    ! non-stub GLC model. These won't change throughout the run, but we can't count on
    ! their being set in initialization, so need to get them in the run method.

    call seq_infodata_GetData( infodata, &
         rof_prognostic=rof_prognostic, &
         glc_present=glc_present)

    ! Map MCT to land data type
    ! Perform downscaling if appropriate


    ! Map to clm (only when state and/or fluxes need to be updated)

    call t_startf ('lc_lnd_import')
    call lnd_import( bounds, &
         x2l = x2l_l%rattr, &
         glc_present = glc_present, &
         atm2lnd_inst = atm2lnd_inst, &
         glc2lnd_inst = glc2lnd_inst, &
         wateratm2lndbulk_inst = water_inst%wateratm2lndbulk_inst)
    call t_stopf ('lc_lnd_import')

    ! Use infodata to set orbital values if updated mid-run

    call seq_infodata_GetData( infodata, orb_eccen=eccen, orb_mvelpp=mvelpp, &
         orb_lambm0=lambm0, orb_obliqr=obliqr )

    ! Loop over time steps in coupling interval

    dosend = .false.
    do while(.not. dosend)

       ! Determine if dosend
       ! When time is not updated at the beginning of the loop - then return only if
       ! are in sync with clock before time is updated
       !
       ! NOTE(wjs, 2020-03-09) I think the do while (.not. dosend) loop only is important
       ! for the first time step (when we run 2 steps). After that, we now assume that we
       ! run one time step per coupling interval (based on setting the model's dtime from
       ! the driver). (According to Mariana Vertenstein, sub-cycling (running multiple
       ! land model time steps per coupling interval) used to be supported, but hasn't
       ! been fully supported for a long time.) We may want to rework this logic to make
       ! this more explicit, or - ideally - get rid of this extra time step at the start
       ! of the run, at which point I think we could do away with this looping entirely.

       call get_curr_date( yr, mon, day, tod )
       ymd = yr*10000 + mon*100 + day
       tod = tod
       dosend = (seq_timemgr_EClockDateInSync( EClock, ymd, tod))

       ! Determine doalb based on nextsw_cday sent from atm model

       nstep = get_nstep()
       caldayp1 = get_curr_calday(offset=dtime, reuse_day_365_for_day_366=.true.)
       if (nstep == 0) then
          doalb = .false.
       else if (nstep == 1) then
          doalb = (abs(nextsw_cday- caldayp1) < 1.e-10_r8)
       else
          doalb = (nextsw_cday >= -0.5_r8)
       end if
       call update_rad_dtime(doalb)

       ! Determine if time to write restart and stop

       rstwr = .false.
       if (rstwr_sync .and. dosend) rstwr = .true.
       nlend = .false.
       if (nlend_sync .and. dosend) nlend = .true.

       ! Run clm

       call t_barrierf('sync_clm_run1', mpicom)
       call t_startf ('clm_run')
       call t_startf ('shr_orb_decl')
       calday = get_curr_calday(reuse_day_365_for_day_366=.true.)
       call shr_orb_decl( calday     , eccen, mvelpp, lambm0, obliqr, declin  , eccf )
       call shr_orb_decl( nextsw_cday, eccen, mvelpp, lambm0, obliqr, declinp1, eccf )
       call t_stopf ('shr_orb_decl')
       call clm_drv(doalb, nextsw_cday, declinp1, declin, rstwr, nlend, rdate, rof_prognostic)
       call t_stopf ('clm_run')

       ! Create l2x_l export state - add river runoff input to l2x_l if appropriate

       call t_startf ('lc_lnd_export')
       call lnd_export(bounds, water_inst%waterlnd2atmbulk_inst, lnd2atm_inst, lnd2glc_inst, l2x_l%rattr)
       call t_stopf ('lc_lnd_export')

       ! Advance clm time step

       call t_startf ('lc_clm2_adv_timestep')
       call advance_timestep()
       call t_stopf ('lc_clm2_adv_timestep')

    end do

    ! Check that internal clock is in sync with master clock

    call get_curr_date( yr, mon, day, tod, offset=-dtime )
    ymd = yr*10000 + mon*100 + day
    tod = tod
    if ( .not. seq_timemgr_EClockDateInSync( EClock, ymd, tod ) )then
       call seq_timemgr_EclockGetData( EClock, curr_ymd=ymd_sync, curr_tod=tod_sync )
       write(iulog,*)' clm ymd=',ymd     ,'  clm tod= ',tod
       write(iulog,*)'sync ymd=',ymd_sync,' sync tod= ',tod_sync
       call endrun( sub//":: CLM clock not in sync with Master Sync clock" )
    end if

    ! Reset shr logging to my original values

    call shr_file_setLogUnit (shrlogunit)
    call shr_file_setLogLevel(shrloglev)

#if (defined _MEMTRACE)
    if(masterproc) then
       lbnum=1
       call memmon_dump_fort('memmon.out','lnd_run_mct:end::',lbnum)
       call memmon_reset_addr()
    endif
#endif

    first_call  = .false.

  end subroutine lnd_run_mct

  !====================================================================================
  subroutine lnd_final_mct( EClock, cdata_l, x2l_l, l2x_l)
    !
    ! !DESCRIPTION:
    ! Finalize land surface model

    use seq_cdata_mod   ,only : seq_cdata, seq_cdata_setptrs
    use seq_timemgr_mod ,only : seq_timemgr_EClockGetData, seq_timemgr_StopAlarmIsOn
    use seq_timemgr_mod ,only : seq_timemgr_RestartAlarmIsOn, seq_timemgr_EClockDateInSync
    use esmf
    !
    ! !ARGUMENTS:
    type(ESMF_Clock) , intent(inout) :: EClock    ! Input synchronization clock from driver
    type(seq_cdata)  , intent(inout) :: cdata_l   ! Input driver data for land model
    type(mct_aVect)  , intent(inout) :: x2l_l     ! Import state to land model
    type(mct_aVect)  , intent(inout) :: l2x_l     ! Export state from land model
    !---------------------------------------------------------------------------

    ! fill this in
  end subroutine lnd_final_mct

  !====================================================================================
  subroutine lnd_domain_mct( bounds, lsize, gsMap_l, dom_l )
    !
    ! !DESCRIPTION:
    ! Send the land model domain information to the coupler
    !
    ! !USES:
    use clm_varcon  , only: re
    use domainMod   , only: ldomain
    use spmdMod     , only: iam
    use mct_mod     , only: mct_gGrid_importIAttr
    use mct_mod     , only: mct_gGrid_importRAttr, mct_gGrid_init, mct_gsMap_orderedPoints
    use seq_flds_mod, only: seq_flds_dom_coord, seq_flds_dom_other
    !
    ! !ARGUMENTS:
    type(bounds_type), intent(in)  :: bounds  ! bounds
    integer        , intent(in)    :: lsize   ! land model domain data size
    type(mct_gsMap), intent(inout) :: gsMap_l ! Output land model MCT GS map
    type(mct_ggrid), intent(out)   :: dom_l   ! Output domain information for land model
    !
    ! Local Variables
    integer :: g,i,j              ! index
    real(r8), pointer :: data(:)  ! temporary
    integer , pointer :: idata(:) ! temporary
    !---------------------------------------------------------------------------
    !
    ! Initialize mct domain type
    ! lat/lon in degrees,  area in radians^2, mask is 1 (land), 0 (non-land)
    ! Note that in addition land carries around landfrac for the purposes of domain checking
    !
    call mct_gGrid_init( GGrid=dom_l, CoordChars=trim(seq_flds_dom_coord), &
       OtherChars=trim(seq_flds_dom_other), lsize=lsize )
    !
    ! Allocate memory
    !
    allocate(data(lsize))
    !
    ! Determine global gridpoint number attribute, GlobGridNum, which is set automatically by MCT
    !
    call mct_gsMap_orderedPoints(gsMap_l, iam, idata)
    call mct_gGrid_importIAttr(dom_l,'GlobGridNum',idata,lsize)
    !
    ! Determine domain (numbering scheme is: West to East and South to North to South pole)
    ! Initialize attribute vector with special value
    !
    data(:) = -9999.0_R8
    call mct_gGrid_importRAttr(dom_l,"lat"  ,data,lsize)
    call mct_gGrid_importRAttr(dom_l,"lon"  ,data,lsize)
    call mct_gGrid_importRAttr(dom_l,"area" ,data,lsize)
    call mct_gGrid_importRAttr(dom_l,"aream",data,lsize)
    data(:) = 0.0_R8
    call mct_gGrid_importRAttr(dom_l,"mask" ,data,lsize)
    !
    ! Fill in correct values for domain components
    ! Note aream will be filled in in the atm-lnd mapper
    !
    do g = bounds%begg,bounds%endg
       i = 1 + (g - bounds%begg)
       data(i) = ldomain%lonc(g)
    end do
    call mct_gGrid_importRattr(dom_l,"lon",data,lsize)

    do g = bounds%begg,bounds%endg
       i = 1 + (g - bounds%begg)
       data(i) = ldomain%latc(g)
    end do
    call mct_gGrid_importRattr(dom_l,"lat",data,lsize)

    do g = bounds%begg,bounds%endg
       i = 1 + (g - bounds%begg)
       data(i) = ldomain%area(g)/(re*re)
    end do
    call mct_gGrid_importRattr(dom_l,"area",data,lsize)

    do g = bounds%begg,bounds%endg
       i = 1 + (g - bounds%begg)
       data(i) = real(ldomain%mask(g), r8)
    end do
    call mct_gGrid_importRattr(dom_l,"mask",data,lsize)

    do g = bounds%begg,bounds%endg
       i = 1 + (g - bounds%begg)
       data(i) = real(ldomain%frac(g), r8)
    end do
    call mct_gGrid_importRattr(dom_l,"frac",data,lsize)

    deallocate(data)
    deallocate(idata)

  end subroutine lnd_domain_mct

  !====================================================================================
  subroutine lnd_handle_resume( cdata_l )
    !
    ! !DESCRIPTION:
    ! Handle resume signals for Data Assimilation (DA)
    !
    ! !USES:
    use clm_time_manager , only : update_DA_nstep
    use seq_cdata_mod    , only : seq_cdata, seq_cdata_setptrs
    implicit none
    ! !ARGUMENTS:
    type(seq_cdata),            intent(inout) :: cdata_l          ! Input land-model driver data
    ! !LOCAL VARIABLES:
    logical :: resume_from_data_assim                      ! flag if we are resuming after data assimulation was done
    !---------------------------------------------------------------------------

    ! Check to see if restart was modified and we are resuming from data
    ! assimilation
    call seq_cdata_setptrs(cdata_l, post_assimilation=resume_from_data_assim)
    if ( resume_from_data_assim ) call update_DA_nstep()

  end subroutine lnd_handle_resume

end module lnd_comp_mct
