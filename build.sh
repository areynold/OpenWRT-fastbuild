#!/bin/bash
# This script pulls allows you to execute a build within a pre-established build environment, complete with pre-built tools and toolchain.  
# The script assumes that a succssful build has already been run within the $BUILD_DIR folder, 
# and that the folder obtained from $FETCH_SRC is located immediately under (within) $BUILD_DIR.
# The script automatically cleans the existing build tree, clones a new copy of the INIT_CLONE_SRC repo into $TEMP_DIR,
# checks out a fresh copy of the OpenWRT build system into this directory, and then copies all of the new files into the pre-existing
# build tree.  The script then opens a command prompt, which allows the user to make any desired changes to feeds, menuconfig, makefiles, etc.
# Once this subshell is closed, the build will proceed.  At the end of the build, the script will the entirety of the bin/ar71xx directory
# to $FINAL_BIN_DEST, which is by default set to $WORKSPACE/bin.

# IMPORTANT NOTE: Please do not execute any part of the build "manually" - let the script do everything for you, and/or modify the script 
# to get it to do want you want.  The script embeds several non-intuitive assumptions, which you may run afoul of if you try to go "off-script"
# TODO: Add checks for validity of workspace, if downloads directory is usable.  Decompose functions further

umask 002
WORKSPACE="/tmp"
BUILD_DIR="$WORKSPACE/build"
TEMP_DIR="$WORKSPACE/openwrt-tmp"
FETCH_SRC="cd $TEMP_DIR; git clone https://github.com/opentechinstitute/commotion-router.git; cd commotion-router; ./setup.sh; cd openwrt"
#FETCH_SRC=". `pwd`/multioption_custom_image.sh $TEMP_DIR"
DOWNLOAD_DIR="$WORKSPACE/downloads"
FINAL_BIN_DEST="$WORKSPACE/bin"
LOCKFILE="$BUILD_DIR/.lock"
INTERVENE=3
CLEAN_ONLY=0
#BUILD_OUTPUT_LOGFILE="$WORKSPACE/build.log"
#FINISH_BUILD_HANDLER="$WORKSPACE/finish_build.sh"

USAGE=$(cat <<END_OF_USAGE
Usage:
-b, --buildir
	Specify location of pre-populated build tree (the main source repo is expected to exist in this location)
-c, --clean
	Clean only
-d, --downloaddir
	Specify location of the downloads cache
-i, --intervene
	Specify degree of manual intervention desired from 0-3, where 0 signifies none (for scripting) and 3 signifies a lot
-f, --finishbuild
	Script to be run at the completion of the build process
-o, --output
	Output logfile; all script output sent to standard out if this is unset
-p, --prepbuild
	Script to be run after build tree is cleaned and repopulated with new feed info
-s, --source
        Exact command to be run (via eval) to fetch a working copy of the source code.  By default, this is a call to multioption_custom_image.sh
-t, --tempdir
	Location to which temporary files will be downloaded
-w, --workspace
	Default "root" of entire build envionment, in which all other important directories and files are expected to exist, unless otherwise specified
--bindest
	Where to put the final binaries
-l, --lock
	Location of lock file
-h, --help
	Print this help message and exit\n
END_OF_USAGE
)

ARGS=`getopt -o "b:c:d:hi:p:s:t:w:f:o:l:" -l "builddir:,clean,downloaddir:,help,intervene:,output:,prepbuild:,source:,tempdir:,workspace:,bindest:,lock:" -- "$@"`

if [ $? -ne 0 ]; then
 exit 1
fi

while (( $# )); do
  case "$1" in
    -b|--builddir)
      shift;
      BUILD_DIR="$1"
      shift;
      ;;
    -c|--clean)
      shift;
      CLEAN_ONLY=1
      ;;
    -d|--downloaddir)
      shift;
      DOWNLOAD_DIR="$1"
      shift;
      ;;
    -f|--finishbuild)
      shift;
      FINISH_BUILD_HANDLER="$1"
      shift;
      ;;
    -i|--intervene)
      shift;
      INTERVENE="$1"
      shift;
      ;;
    -o|--output)
      shift;
      BUILD_OUTPUT_LOGFILE="$1"
      shift;
      ;;
    -p|--prepbuild)
      shift;
      CUSTOM_BUILD_HANDLER="$1"
      shift;
      ;;
    -s|--source)
      shift;
      FETCH_SRC="$1"
      shift;
      ;;
    -t|--tempdir)
      shift;
      TEMP_DIR="$1"
      shift;
      ;;
    -w|--workspace)
      shift;
      WORKSPACE="$1"
      shift;
      ;;
    --bindest)
      shift;
      FINAL_BIN_DEST="$1"
      shift;
      ;;
    -l|--lock)
      shift;
      LOCKFILE="$1"
      shift;
      ;;
    -h|--help)
      echo -e "$USAGE"
      exit 0
      ;;
    *)
      echo -e "$USAGE"
      exit 1 
      ;;
  esac
done

#REPO_NAME=`echo "$FETCH_SRC" | sed -e 's,.*/.*/,,g' -e 's,\..*,,g'`
REPO_NAME="commotion-router"

if [ ! -e "$WORKSPACE" ]; then
 echo "Workspace $WORKSPACE does not exist!  Create it, then restart the build script"
 exit 1
fi
if [ ! -e "$BUILD_DIR" ]; then
 echo "Build directory $BUILD_DIR does not exist!  Create it, then restart the build script"
 exit 1
fi
if [ ! -e "$DOWNLOAD_DIR" ]; then
 echo "Download directory $DOWNLOAD_DIR does not exist!  Create it, then restart the build script"
 exit 1
fi
if [ ! -e "$TEMP_DIR" ]; then
 echo "Temporary directory $TEMP_DIR does not exist!  Create it, then restart the build script"
 exit 1
fi

if [ "$BUILD_DIR/$REPO_NAME/openwrt/toolchain/Makefile" -nt "$BUILD_DIR/$REPO_NAME/openwrt/build_dir/toolchain-mips_r2_gcc-4.6-linaro_uClibc-0.9.33.2" ]; then
 echo "Specified workspace does not contain a pre-populated build tree!  Please run a full build in $BUILD_DIR, then try again"
 exit 1
fi

if [[ `id -u` != `stat $BUILD_DIR/$REPO_NAME -c %u` ]]; then
 echo "You must be the owner (\"`stat $BUILD_DIR/$REPO_NAME -c %U`\") of the entire build tree ($BUILD_DIR) to run this script!  Exiting..."
 exit 1
fi

if [ -e "$LOCKFILE" ]; then
 echo "Lockfile found! A build is already in progress.  Exiting..."
 exit 1
else
 touch "$LOCKFILE"
fi

function cleanBuildTree {
 echo "Cleaning up build environment..."
 if [ -e "$TEMP_DIR/$REPO_NAME" ]; then
  rm -rf "$TEMP_DIR/$REPO_NAME"
 fi
 pushd "$BUILD_DIR/$REPO_NAME/openwrt"
 if [ -e build_dir/linux-ar71xx_generic ]; then
  make clean
  find . -type d -not -name '.' -not -regex ".*/\(logs\|toolchain\|tools\|staging_dir\|build_dir\|.*/\).*" | xargs rm -rf
  find . -type f -not -name '.' -not -regex ".*/\(logs\|toolchain\|tools\|staging_dir\|build_dir\)/.*" | xargs rm -f
  cd "$BUILD_DIR/$REPO_NAME"
  find . -not -name '.' -not -regex ".*openwrt.*" | xargs rm -rf
  find . -type d -name '.svn' -o -name 'target-mips_r2_uClibc-0.9.33.2' | xargs rm -rf
 fi
 popd
 echo "Done!"
}

function intervene {
 echo 'Opening a shell within the build environment. Enter "go" to continue the normal automated process, and "stop" to abort the process.'
 bash
 if [ $? -eq 5 ]; then
  echo "Aborting the script."
  rm "$LOCKFILE"
  exit
 else
  echo "Continuing the script..."
 fi
}

function go {
 exit 0
}
function stop {
 exit 5
}
export -f go stop

if [ -x `echo $FETCH_SRC | cut -d ' ' -f 1` ]; then 
 FETCH_SRC=". $FETCH_SRC"
else 
 FETCH_SRC="eval $FETCH_SRC"
fi

cleanBuildTree
if [ "$CLEAN_ONLY" -eq 1 ]; then
 rm "$LOCKFILE"
 exit
fi

#if [ "$INTERVENE" -gt 2 ]; then
# echo "Make changes to ./setup or any other part of the initial build tree before ./setup runs."
# intervene
#fi

echo "Fetching source to $TEMP_DIR..."
pushd "$TEMP_DIR"
echo "Fetching and unpacking source into $TEMP_DIR..."
if [ -n "$BUILD_OUTPUT_LOGFILE" ]; then
 $FETCH_SRC 2>&1 | tee "$BUILD_OUTPUT_LOGFILE"
else
 $FETCH_SRC
fi
#cd $SRC_DIR
#cd "$REPO_NAME"

#Fix for specific bug in serval package that extracts version info from git
cp -rf ../.git* "$BUILD_DIR/$REPO_NAME/"

#cd openwrt

if [ "$INTERVENE" -gt 0 ]; then
 echo "Almost ready to build! Make any changes you wish to feeds, menuconfig, or specific files at the prompt below.  Your working (temporary) files will then be copied into the final build tree, and built."
 intervene
fi

echo "Setting specified download directory and other build options..."
sed -i .config -e 's,.*CONFIG_CCACHE.*,CONFIG_CCACHE=y,'
sed -i .config -e "s,CONFIG_DOWNLOAD_FOLDER=\"\",CONFIG_DOWNLOAD_FOLDER=\"$DOWNLOAD_DIR\","

echo "Moving dynamic elements of build tree from $TEMP_DIR to build directory $BUILD_DIR..."
rm -rf  staging_dir tools toolchain
cp -rf . "$BUILD_DIR/$REPO_NAME/openwrt"

echo "Selectively purging downloads directory..."
find "$DOWNLOAD_DIR" -regex ".*\(commotion\|luci\|serval\|olsrd\|avahi\|batphone\|nodog\).*" | xargs rm -f

cd "$BUILD_DIR/$REPO_NAME/openwrt"
rm -rf "$SRC_DIR"
#rm -rf "$TEMP_DIR/$REPO_NAME"

if [ -n "$BUILD_OUTPUT_LOGFILE" ]; then
 make -j 13 2>&1 | tee "$BUILD_OUTPUT_LOGFILE"
else
 make -j 13
fi

if [ "$INTERVENE" -gt 1 ]; then
 echo "The main OpenWRT build process is complete.  If you wish to check or extract anything in the build tree before it is cleaned up, do so now."
 intervene
fi

echo "Moving built binaries to $FINAL_BIN_DEST..."
while true; do
 if [[ -e bin/ar71xx ]] && [[ -d "$FINAL_BIN_DEST" ]]; then 
  cp -rf bin/ar71xx "$FINAL_BIN_DEST"
  chmod -Rf g+w "$FINAL_BIN_DEST"
  cleanBuildTree
  break
 else 
 echo "Error copying images to $FINAL_BIN_DEST. Either the images were not created successfully or $FINAL_BIN_DEST is not a writable destination.  Now opening a shell so that you can investigate, modify $FINAL_BIN_DEST, and/or try to rebuild without reinitiating the entire process. Remember - you're still in the build process!  To get out of it, just type \"stop\"."
 intervene
 fi
done
echo "Done!"

chmod -Rf g+w "$BUILD_DIR/$REPO_NAME"
find "$DOWNLOAD_DIR" -user `whoami` ! -perm -g+w | xargs chmod g+w
rm "$LOCKFILE"

if [ -e "$FINISH_BUILD_HANDLER" ]; then
 . "$FINISH_BUILD_HANDLER"
elif [ -n "$FINISH_BUILD_HANDLER" ]; then
  echo "Build finishing script, $FINISH_BUILD_HANDLER, does not exist! Skipping..."
fi

exit
