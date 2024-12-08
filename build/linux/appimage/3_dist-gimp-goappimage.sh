#!/bin/sh

# Loosely based on:
# https://github.com/AppImage/AppImageSpec/blob/master/draft.md
# https://gitlab.com/inkscape/inkscape/-/commit/b280917568051872793a0c7223b8d3f3928b7d26

set -e

if [ -z "$GITLAB_CI" ]; then
  # Make the script work locally
  if [ "$0" != 'build/linux/appimage/3_dist-gimp-goappimage.sh' ] && [ ${PWD/*\//} != 'appimage' ]; then
    echo -e '\033[31m(ERROR)\033[0m: Script called from wrong dir. Please, call this script from the root of gimp git dir'
    exit 1
  elif [ ${PWD/*\//} = 'appimage' ]; then
    cd ../../..
  fi
fi


# 1. INSTALL GO-APPIMAGETOOL AND COMPLEMENTARY TOOLS
if [ -f "*appimagetool*.AppImage" ]; then
  rm *appimagetool*.AppImage
fi
if [ "$GITLAB_CI" ]; then
  apt-get install -y --no-install-recommends wget >/dev/null 2>&1
fi
export ARCH=$(uname -m)
export APPIMAGE_EXTRACT_AND_RUN=1

## For now, we always use the latest version of go-appimagetool for bundling. See: https://github.com/probonopd/go-appimage/issues/275
echo '(INFO): downloading go-appimagetool'
wget -c https://github.com/$(wget -q https://github.com/probonopd/go-appimage/releases/expanded_assets/continuous -O - | grep "appimagetool-.*-${ARCH}.AppImage" | head -n 1 | cut -d '"' -f 2) >/dev/null 2>&1
echo "(INFO): Downloaded go-appimagetool: $(echo appimagetool-*.AppImage | sed -e 's/appimagetool-//' -e "s/-${ARCH}.AppImage//")"
go_appimagetool='go-appimagetool.AppImage'
mv appimagetool-*.AppImage $go_appimagetool
chmod +x "$go_appimagetool"

## go-appimagetool does not patch LD interpreter so we use patchelf. See: https://github.com/probonopd/go-appimage/issues/49
if [ "$GITLAB_CI" ]; then
  apt-get install -y --no-install-recommends patchelf >/dev/null 2>&1
fi

## standard appimagetool is needed for squashing the .appimage file. See: https://github.com/probonopd/go-appimage/issues/86
if [ "$GITLAB_CI" ]; then
  apt-get install -y --no-install-recommends zsync >/dev/null 2>&1
fi
wget "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage" >/dev/null 2>&1
standard_appimagetool='legacy-appimagetool.AppImage'
mv appimagetool-*.AppImage $standard_appimagetool
chmod +x "$standard_appimagetool"


# 2. GET GLOBAL VARIABLES

## Dir to get info about GIMP version
if [ "$1" ]; then
  export BUILD_DIR="$1"
else
  export BUILD_DIR="$PWD/_build"
fi
GIMP_UNSTABLE=$(grep -q '#define GIMP_UNSTABLE' $BUILD_DIR/config.h)
GIMP_VERSION=$(grep GIMP_VERSION $BUILD_DIR/config.h | head -1 | sed 's/^.*"\([^"]*\)"$/\1/')
if [ "$GIMP_UNSTABLE" ] || [[ "$GIMP_VERSION" =~ 'git' ]]; then
  export CHANNEL='continuous'
else
  export CHANNEL='latest'
fi
export APP_ID="org.gimp.GIMP.$CHANNEL"

## Prefixes to get files to copy
UNIX_PREFIX='/usr'
if [ -z "$GITLAB_CI" ] && [ -z "$GIMP_PREFIX" ]; then
  export GIMP_PREFIX="$PWD/../_install"
fi

## Paths to receive copied files
APP_DIR="$PWD/AppDir"
USR_DIR="$APP_DIR/usr"


# 3. GIMP FILES

## 3.1. Special re-building (only if needed)

### Prepare env. Universal variables from .gitlab-ci.yml
if [ -z "$GITLAB_CI" ]; then
  IFS=$'\n' VAR_ARRAY=($(cat .gitlab-ci.yml | sed -n '/export PATH=/,/GI_TYPELIB_PATH}\"/p' | sed 's/    - //'))
  IFS=$' \t\n'
  for VAR in "${VAR_ARRAY[@]}"; do
    eval "$VAR" || continue
  done
fi

### Ensure that GIMP is relocatable
grep -q 'relocatable-bundle=yes' $BUILD_DIR/meson-logs/meson-log.txt && export RELOCATABLE_BUNDLE_ON=1
if [ -z "$RELOCATABLE_BUNDLE_ON" ]; then
  echo "(INFO): building GIMP as relocatable"
  if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    meson setup $BUILD_DIR -Drelocatable-bundle=yes >/dev/null 2>&1
  else
    meson configure $BUILD_DIR -Drelocatable-bundle=yes >/dev/null 2>&1
  fi
  cd $BUILD_DIR
  ninja &> ninja.log | rm ninja.log || cat ninja.log
  ninja install >/dev/null 2>&1
  ccache --show-stats
  cd ..
fi


## 3.2. Bundle files
prep_pkg ()
{
  if [ "$GITLAB_CI" ]; then
    apt-get install -y --no-install-recommends $1 >/dev/null 2>&1
  fi
}

bund_usr ()
{
  if [ "$3" != '--go' ]; then
    #Prevent unwanted expansion
    mkdir -p limbo
    cd limbo

    #Paths where to search
    case $2 in
      bin*)
        search_path=("$1/bin" "/usr/sbin" "/usr/libexec")
        ;;
      lib*)
        search_path=("$(dirname $(echo $2 | sed "s|lib/|$1/${LIB_DIR}/${LIB_SUBDIR}|g" | sed "s|*|no_scape|g"))"
                     "$(dirname $(echo $2 | sed "s|lib/|/usr/${LIB_DIR}/|g" | sed "s|*|no_scape|g"))")
        ;;
      share*|etc*)
        search_path=("$(dirname $(echo $2 | sed "s|${2%%/*}|$1/${2%%/*}|g" | sed "s|*|no_scape|g"))")
        ;;
    esac
    for path in "${search_path[@]}"; do
      expanded_path=$(echo $(echo $path | sed "s|no_scape|*|g"))
      if [ ! -d "$expanded_path" ]; then
        break
      fi

      #Copy found targets from search_path to bundle dir
      echo "expanded path is $expanded_path"
      target_array=($(find $expanded_path -maxdepth 1 -name ${2##*/}))
      for target_path in "${target_array[@]}"; do
        echo "target path is $target_path"
        dest_path="$(dirname $(echo $target_path | sed "s|$1/|${USR_DIR}/|g"))"
        if [ "$3" = '--dest' ]; then
          dest_path="${USR_DIR}/$4"
          mode='-L'
        fi
        echo "dest path is $dest_path"
        mkdir -p $dest_path
        if [ -d "$target_path" ] || [ -f "$target_path" ]; then
          cp -ru $mode $target_path $dest_path >/dev/null 2>&1 || continue
        fi
        unset mode
        if [ "$3" = '--rename' ]; then
          mv $dest_path/${2##*/} $dest_path/$4
        fi
        echo "------------------"
      done
    done

    #Undo the tweak done above
    cd ..
    rm -r limbo
  fi
}

conf_app ()
{
  #Make backup of AppRun before changing it
  if [ ! -f 'build/linux/appimage/AppRun.bak' ]; then
    cp build/linux/appimage/AppRun build/linux/appimage/AppRun.bak
  fi

  #Prefix from which to expand the var
  prefix=$UNIX_PREFIX
  case $1 in
    *BABL*|*GEGL*|*GIMP*)
      prefix=$GIMP_PREFIX
  esac

  #Set expanded var in AppRun (and temporarely in environ if needed by this script)
  var_path=$(echo $prefix/$2 | sed "s|${prefix}/||g")
  sed -i "s|${1}_WILD|usr/${var_path}|" build/linux/appimage/AppRun
  eval $1="usr/$var_path"
}

wipe_usr ()
{
  cleanedArray=($(find $USR_DIR -iname ${1##*/}))
  for path_dest_full in "${cleanedArray[@]}"; do
    rm -r -f $path_dest_full
  done
}

## Prepare AppDir
echo '(INFO): copying files to AppDir/usr'
mkdir -p $APP_DIR
bund_usr "$UNIX_PREFIX" "lib64/ld-*.so.*" --go
conf_app LD_LINUX "lib64/ld-*.so.*"

## Bundle base (bare minimum to run GTK apps)
### Glib needed files (to be able to use file dialogs)
bund_usr "$UNIX_PREFIX" "share/glib-*/schemas"
### Glib commonly required modules
prep_pkg "gvfs"
bund_usr "$UNIX_PREFIX" "lib/gvfs*"
bund_usr "$UNIX_PREFIX" "bin/gvfs*" --dest "${LIB_DIR}/gvfs"
bund_usr "$UNIX_PREFIX" "lib/gio*"
conf_app GIO_MODULE_DIR "${LIB_DIR}/${LIB_SUBDIR}gio"
### GTK needed files (to be able to load icons)
bund_usr "$UNIX_PREFIX" "share/icons/Adwaita"
bund_usr "$GIMP_PREFIX" "share/icons/hicolor"
bund_usr "$UNIX_PREFIX" "share/mime"
bund_usr "$UNIX_PREFIX" "lib/gdk-pixbuf-*" --go
conf_app GDK_PIXBUF_MODULEDIR "${LIB_DIR}/${LIB_SUBDIR}gdk-pixbuf-*/*.*.*"
conf_app GDK_PIXBUF_MODULE_FILE "${LIB_DIR}/${LIB_SUBDIR}gdk-pixbuf-*/*.*.*"
### GTK commonly required modules
prep_pkg "libibus-1.0-5"
bund_usr "$UNIX_PREFIX" "lib/libibus*"
prep_pkg "ibus-gtk3"
prep_pkg "libcanberra-gtk3-module"
prep_pkg "libxapp-gtk3-module"
bund_usr "$UNIX_PREFIX" "lib/gtk-*" --go
conf_app GTK_PATH "${LIB_DIR}/${LIB_SUBDIR}gtk-3.0"
conf_app GTK_IM_MODULE_FILE "${LIB_DIR}/${LIB_SUBDIR}gtk-3.0/*.*.*"

## Core features
bund_usr "$GIMP_PREFIX" "lib/libbabl*"
bund_usr "$GIMP_PREFIX" "lib/babl-*"
conf_app BABL_PATH "${LIB_DIR}/${LIB_SUBDIR}babl-*"
bund_usr "$GIMP_PREFIX" "lib/libgegl*"
bund_usr "$GIMP_PREFIX" "lib/gegl-*"
conf_app GEGL_PATH "${LIB_DIR}/${LIB_SUBDIR}gegl-*"
bund_usr "$GIMP_PREFIX" "lib/libgimp*"
bund_usr "$GIMP_PREFIX" "lib/gimp"
conf_app GIMP3_PLUGINDIR "${LIB_DIR}/${LIB_SUBDIR}gimp/*"
bund_usr "$GIMP_PREFIX" "share/gimp"
conf_app GIMP3_DATADIR "share/gimp/*"
lang_array=($(echo $(ls po/*.po |
              sed -e 's|po/||g' -e 's|.po||g' | sort) |
              tr '\n\r' ' '))
for lang in "${lang_array[@]}"; do
  bund_usr "$GIMP_PREFIX" share/locale/$lang/LC_MESSAGES
  bund_usr "$UNIX_PREFIX" share/locale/$lang/LC_MESSAGES/gtk3*.mo
  # For language list in text tool options
  bund_usr "$UNIX_PREFIX" share/locale/$lang/LC_MESSAGES/iso_639*3.mo
done
conf_app GIMP3_LOCALEDIR "share/locale"
bund_usr "$GIMP_PREFIX" "etc/gimp"
conf_app GIMP3_SYSCONFDIR "etc/gimp/*"

## Other features and plug-ins
### Needed for welcome page
bund_usr "$GIMP_PREFIX" "share/metainfo/*.xml" --rename $APP_ID.appdata.xml
sed -i '/kudo/d' $USR_DIR/share/metainfo/$APP_ID.appdata.xml
sed -i "s/date=\"TODO\"/date=\"`date --iso-8601`\"/" $USR_DIR/share/metainfo/$APP_ID.appdata.xml
### mypaint brushes
bund_usr "$UNIX_PREFIX" "share/mypaint-data/1.0"
### Needed for full CJK and Cyrillic support in file-pdf
bund_usr "$UNIX_PREFIX" "share/poppler"
### file-wmf support (not portable, depends on how the distro deals with PS fonts)
#bund_usr "$UNIX_PREFIX" "share/libwmf"
if [ "$GIMP_UNSTABLE" ]; then
  ### Image graph support
  bund_usr "$UNIX_PREFIX" "bin/libgvc*" --rename "bin/dot"
  bund_usr "$UNIX_PREFIX" "lib/graphviz/config*"
  bund_usr "$UNIX_PREFIX" "lib/graphviz/libgvplugin_dot*"
  bund_usr "$UNIX_PREFIX" "lib/graphviz/libgvplugin_pango*"
  ### Needed for GTK inspector
  bund_usr "$UNIX_PREFIX" "lib/libEGL*"
  bund_usr "$UNIX_PREFIX" "lib/libGL*"
  bund_usr "$UNIX_PREFIX" "lib/dri*"
fi
### FIXME: Debug dialog (NOT WORKING)
#bund_usr "$UNIX_PREFIX" "bin/lldb*"
#bund_usr "$GIMP_PREFIX" "libexec/gimp-debug-tool*"
### Introspected plug-ins
bund_usr "$GIMP_PREFIX" "lib/girepository-*"
bund_usr "$UNIX_PREFIX" "lib/girepository-*"
conf_app GI_TYPELIB_PATH "${LIB_DIR}/${LIB_SUBDIR}girepository-*"
#### JavaScript plug-ins support
bund_usr "$UNIX_PREFIX" "bin/gjs*"
bund_usr "$UNIX_PREFIX" "lib/gjs/girepository-1.0/Gjs*" --dest "${LIB_DIR}/${LIB_SUBDIR}girepository-1.0"
#### Python plug-ins support
bund_usr "$UNIX_PREFIX" "bin/python*"
bund_usr "$UNIX_PREFIX" "lib/python*"
wipe_usr ${LIB_DIR}/*.pyc
#### Lua plug-ins support (NOT WORKING and buggy)
#bund_usr "$UNIX_PREFIX" "bin/luajit*"
#bund_usr "$UNIX_PREFIX" "lib/lua"
#bund_usr "$UNIX_PREFIX" "share/lua"

## Other binaries and deps
bund_usr "$GIMP_PREFIX" 'bin/gimp*'
bund_usr "$GIMP_PREFIX" "bin/gegl"
bund_usr "$GIMP_PREFIX" "share/applications/*.desktop" --rename $APP_ID.desktop
"./$go_appimagetool" -s deploy $USR_DIR/share/applications/$APP_ID.desktop &> appimagetool.log

## Manual adjustments (go-appimagetool don't handle Linux FHS gracefully yet)
### Ensure that LD is in right dir. See: https://github.com/probonopd/go-appimage/issues/49
cp -r $APP_DIR/lib64 $USR_DIR
rm -r $APP_DIR/lib64
chmod +x "$APP_DIR/$LD_LINUX"
exec_array=($(find "$USR_DIR/bin" "$USR_DIR/$LIB_DIR" ! -iname "*.so*" -type f -exec head -c 4 {} \; -exec echo " {}" \;  | grep ^.ELF))
for exec in "${exec_array[@]}"; do
  if [[ ! "$exec" =~ 'ELF' ]]; then
    patchelf --set-interpreter "./$LD_LINUX" "$exec" >/dev/null 2>&1 || continue
  fi
done
### Undo the mess which breaks babl and GEGL. See: https://github.com/probonopd/go-appimage/issues/315
cp -r $APP_DIR/lib/* $USR_DIR/${LIB_DIR}
rm -r $APP_DIR/lib
### Remove unnecessary files bundled by go-appimagetool
wipe_usr ${LIB_DIR}/${LIB_SUBDIR}gconv
wipe_usr ${LIB_DIR}/${LIB_SUBDIR}gdk-pixbuf-*/gdk-pixbuf-query-loaders
wipe_usr share/doc
wipe_usr share/themes
rm -r $APP_DIR/etc


# 4. PREPARE .APPIMAGE-SPECIFIC "SOURCE"

## 4.1. Finish AppRun configuration
echo '(INFO): copying configured AppRun asset'
sed -i '/_WILD/d' build/linux/appimage/AppRun
mv build/linux/appimage/AppRun $APP_DIR
chmod +x $APP_DIR/AppRun
mv build/linux/appimage/AppRun.bak build/linux/appimage/AppRun

## 4.2. Copy icon assets (similarly to flatpaks's 'rename-icon')
echo "(INFO): copying $APP_ID.svg asset to AppDir"
find "$USR_DIR/share/icons/hicolor" -iname *.svg -execdir ln -s "{}" $APP_ID.svg \;
find "$USR_DIR/share/icons/hicolor" -iname *.png -execdir ln -s "{}" $APP_ID.png \;
cp $GIMP_PREFIX/share/icons/hicolor/scalable/apps/*.svg $APP_DIR

## 4.3. Configure .desktop asset (similarly to flatpaks's 'rename-desktop-file')
echo "(INFO): configuring $APP_ID.desktop asset"
sed -i "s/Icon=gimp/Icon=$APP_ID/g" "$USR_DIR/share/applications/${APP_ID}.desktop"

## 4.4. Configure appdata asset (similarly to flatpaks's 'rename-appdata-file')
echo "(INFO): configuring $APP_ID.appdata.xml asset"
sed -i "s/org.gimp.GIMP/${APP_ID}/g" "$USR_DIR/share/metainfo/${APP_ID}.appdata.xml"
sed -i "s/gimp.desktop/${APP_ID}.desktop/g" "$USR_DIR/share/metainfo/${APP_ID}.appdata.xml"


# 5. CONSTRUCT .APPIMAGE
appimage_artifact="GIMP-${gimp_version}-${ARCH}.AppImage"
echo "(INFO): making $appimage_artifact"
"./$standard_appimagetool" -n $APP_DIR $appimage_artifact &>> appimagetool.log -u "zsync|https://gitlab.gnome.org/GNOME/gimp/-/jobs/artifacts/master/raw/build/linux/appimage/_Output/GIMP-${CHANNEL}-${ARCH}.AppImage.zsync?job=dist-appimage-weekly"
rm -r $APP_DIR

chmod +x "./$appimage_artifact"
"./$appimage_artifact" --appimage-version &>> appimagetool.log


if [ "$GITLAB_CI" ]; then
  mkdir -p build/linux/appimage/_Output/
  mv GIMP*.AppImage build/linux/appimage/_Output/
fi
