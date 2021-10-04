"""
Run this code by using the following wrapper script:
tools/modify_fsurdat/fsurdat_modifier

The wrapper script includes a full description and instructions.
"""

#  Import libraries
import sys

from argparse import ArgumentParser, RawDescriptionHelpFormatter

from ctsm.modify_fsurdat.modify_fsurdat import ModifyFsurdat


def get_parser():

    """
    Description
    -----------
    Get parser object for this script.
    """

    parser = ArgumentParser(description=__doc__,
                           formatter_class=RawDescriptionHelpFormatter)

    parser.print_usage = parser.print_help

    # Accepted values

    parser.add_argument('--dom_nat_pft',
                help='Optional non-crop PFT to be set to 100% everywhere ' \
                     '(integer from 0 to natpft; see natpft in your ' \
                     'fsurdat_in file). [default: %(default)s]',
                action="store",
                dest="dom_nat_pft",
                type=int,
                choices=range(0, 15),  # maximum natveg = 14
                default=-999)
    parser.add_argument('--std_elev',
                help='Optional STD_ELEV value to specify uniform snowpack ' \
                     'everywhere (integer from 0 to 100 m). [default: %(default)s]',
                action="store",
                dest="std_elev",
                type=int,
                choices=range(0, 101),  # TODO reasonable range?
                default=-999)
    parser.add_argument('--zero_nonveg',
                help='Optional flag to set non-vegetation landunits to zero. ' \
                     'Redundant if defining new land mask using --lnd_lat_1, ' \
                     '--lnd_lat_2, --lnd_lon_1, and --lnd_lon_2 [default: %(default)s]',
                action="store_true",
                dest="zero_nonveg")
    parser.add_argument('--max_sat_area',
                help='Optional maximum fractional saturated area, aka. FMAX ' \
                     'to set to everywhere (from 0 to 1). [default: %(default)s]',
                action="store",
                dest="max_sat_area",
                type=float,
                default=-999)
    parser.add_argument('--lnd_lat_1',
                help='Optional southernmost latitude for land swath (integer ' \
                     '-90 to 90). If lnd_lat_1 > lnd_lat_2 the code creates ' \
                     'two land swaths, one in the north and one in the ' \
                     'south. Required for lnd_lat_2, lnd_lon_1, and ' \
                     'lnd_lon_2 to work together [default: %(default)s]',
                dest='lnd_lat_1',
                action="store",
                type=int,
                choices=range(-90, 91),
                default=-999)
    parser.add_argument('--lnd_lat_2',
                help='Optional northernmost latitude for land swath (integer ' \
                     '-90 to 90). If lnd_lat_1 > lnd_lat_2 the code creates ' \
                     'two land swaths, one in the north and one in the ' \
                     'south. Required for lnd_lat_1, lnd_lon_1, and ' \
                     'lnd_lon_2 to work together [default: %(default)s]',
                action="store",
                dest="lnd_lat_2",
                type=int,
                choices=range(-90, 91),
                default=-999)
    parser.add_argument('--lnd_lon_1',
                help='Optional minimum longitude for land swath (integer 0 ' \
                     'to 360). If lnd_lon_1 > lnd_lon_2 the land swath wraps ' \
                     'around the 0-degree meridian. Required for lnd_lon_2, ' \
                     'lnd_lat_1, and lnd_lat_2 to work together [default: %(default)s]',
                action="store",
                dest="lnd_lon_1",
                type=int,
                choices=range(0, 361),
                default=-999)
    parser.add_argument('--lnd_lon_2',
                help='Optional maximum longitude for land swath (integer 0 ' \
                     'to 360). If lnd_lon_1 > lnd_lon_2 the land swath wraps ' \
                     'around the 0-degree meridian. Required for lnd_lon_1, ' \
                     'lnd_lat_1, and lnd_lat_2 to work together [default: %(default)s]',
                action="store",
                dest="lnd_lon_2",
                type=int,
                choices=range(0, 361),
                default=-999)
    parser.add_argument('--fsurdat_in',
                help='Path and name of input surface dataset [default: %(default)s]',
                action="store",
                dest="fsurdat_in",
                type=str,
                # TODO: Require user to enter this and remove the default
                default="/glade/p/cesmdata/cseg/inputdata" \
                        "/lnd/clm2/surfdata_map/" \
                        "surfdata_10x15_78pfts_CMIP6_simyr1850_c170824.nc")
    parser.add_argument('--fsurdat_out',
                help='Required path and name of output surface dataset [default: %(default)s]',
                action="store",
                dest="fsurdat_out",
                type=str,
                required=True)  # TODO Doesn't return 'this is required' error

    return parser


def main ():
    """
    Description
    -----------
    Calls various functions that modify an fsurdat (surface dataset)
    """

    # Parse arguments from the command line
    args = get_parser().parse_args()

    # Create ModifyFsurdat object
    modify_fsurdat = ModifyFsurdat(args.fsurdat_in)

    # ------------------------------
    # modify surface data properties
    # ------------------------------

    # 1) Set dom_nat_pft to 100% everywhere
    if args.dom_nat_pft != -999:
        modify_fsurdat.dom_nat_pft(args.dom_nat_pft)

    # 2) Set all non-vegetation landunits to zero
    if args.zero_nonveg:
        modify_fsurdat.zero_nonveg()

    # 3) Create uniform snowpack by setting STD_ELEV to a constant everywhere
    if args.std_elev != -999:
        modify_fsurdat.std_elev(args.std_elev)

    # 4) Set max_sat_area (FMAX) to a constant everywhere
    if args.max_sat_area != -999:
        modify_fsurdat.max_sat_area(args.max_sat_area)

    # 5) Set land swath to land, making all else ocean
    if args.lnd_lon_1 == -999 or args.lnd_lat_1 == -999 or \
       args.lnd_lon_2 == -999 or args.lnd_lat_2 == -999:
        warning_msg = 'Warning: One or more of the optional arguments ' \
                      'lnd_lon_1, lnd_lon_2, lnd_lat_1, lnd_lat_2 were not ' \
                      'set, so all four are ignored.'
        print(warning_msg)  # TODO Use logging for this statement
    else:
        modify_fsurdat.land_swath(args.lnd_lon_1, args.lnd_lon_2,
                                  args.lnd_lat_1, args.lnd_lat_2)

    # ----------------------------------------------
    # Output the now modified CTSM surface data file
    # ----------------------------------------------
    modify_fsurdat.write_output(args.fsurdat_in, args.fsurdat_out)

    sys.exit('SUCCESS')
