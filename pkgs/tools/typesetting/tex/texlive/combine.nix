params: with params;
# combine =
args@{
  pkgFilter ? (pkg: pkg.tlType == "run" || pkg.tlType == "bin" || pkg.pname == "core")
, extraName ? "combined"
, extraVersion ? ""
, ...
}:
let
  pkgSet = removeAttrs args [ "pkgFilter" "extraName" "extraVersion" ] // {
    # include a fake "core" package
    core.pkgs = [
      (bin.core.out // { pname = "core"; tlType = "bin"; })
      (bin.core.doc // { pname = "core"; tlType = "doc"; })
    ];
  };
  pkgList = rec {
    all = lib.filter pkgFilter (combinePkgs pkgSet);
    splitBin = builtins.partition (p: p.tlType == "bin") all;
    bin = mkUniqueOutPaths splitBin.right
      ++ lib.optional
          (lib.any (p: p.tlType == "run" && p.pname == "pdfcrop") splitBin.wrong)
          (lib.getBin ghostscript);
    nonbin = mkUniqueOutPaths splitBin.wrong;

    # extra interpreters needed for shebangs, based on 2015 schemes "medium" and "tetex"
    # (omitted tk needed in pname == "epspdf", bin/epspdftk)
    pkgNeedsPython = pkg: pkg.tlType == "run" && lib.elem pkg.pname
      [ "de-macro" "pythontex" "dviasm" "texliveonfly" ];
    pkgNeedsRuby = pkg: pkg.tlType == "run" && pkg.pname == "match-parens";
    extraInputs =
      lib.optional (lib.any pkgNeedsPython splitBin.wrong) python3
      ++ lib.optional (lib.any pkgNeedsRuby splitBin.wrong) ruby;
  };

  sortedUniqueStrings = list: lib.sort (a: b: a < b) (lib.unique list);

  mkUniqueOutPaths = pkgs: lib.unique
    (map (p: p.outPath) (builtins.filter lib.isDerivation pkgs));

in (buildEnv {
  name = "texlive-${extraName}-${bin.texliveYear}${extraVersion}";

  extraPrefix = "/share/texmf";

  ignoreCollisions = false;
  paths = pkgList.nonbin;
  pathsToLink = [
    "/"
    "/tex/generic/config" # make it a real directory for scheme-infraonly
  ];

  nativeBuildInputs = [ makeWrapper libfaketime perl bin.texlinks ];
  buildInputs = pkgList.extraInputs;

  # This is set primarily to help find-tarballs.nix to do its job
  passthru.packages = pkgList.all;

  postBuild = ''
    mkdir -p "$out"/bin
  '' +
    lib.concatMapStrings
      (path: ''
        for f in '${path}'/bin/*; do
          if [[ -L "$f" ]]; then
            cp -d "$f" "$out"/bin/
          else
            ln -s "$f" "$out"/bin/
          fi
        done
      '')
      pkgList.bin
    +
  ''
    export PATH="$out/bin:$out/share/texmf/scripts/texlive:$PATH"
    export TEXMFCNF="$out/share/texmf/web2c"
    TEXMFSYSCONFIG="$out/share/texmf-config"
    TEXMFSYSVAR="$out/share/texmf-var"
    export PERL5LIB="$out/share/texmf/scripts/texlive:${bin.core.out}/share/texmf-dist/scripts/texlive"
  '' +
    # patch texmf-dist  -> $out/share/texmf
    # patch texmf-local -> $out/share/texmf-local
    # TODO: perhaps do lua actions?
    # tried inspiration from install-tl, sub do_texmf_cnf
  ''
    if [ -e "$TEXMFCNF/texmfcnf.lua" ]; then
      sed \
        -e 's,texmf-dist,texmf,g' \
        -e "s,\(TEXMFLOCAL[ ]*=[ ]*\)[^\,]*,\1\"$out/share/texmf-local\",g" \
        -e "s,\$SELFAUTOLOC,$out,g" \
        -e "s,selfautodir:/,$out/share/,g" \
        -e "s,selfautodir:,$out/share/,g" \
        -e "s,selfautoparent:/,$out/share/,g" \
        -e "s,selfautoparent:,$out/share/,g" \
        -i "$TEXMFCNF/texmfcnf.lua"
    fi

    sed \
      -e 's,texmf-dist,texmf,g' \
      -e "s,\$SELFAUTOLOC,$out,g" \
      -e "s,\$SELFAUTODIR,$out/share,g" \
      -e "s,\$SELFAUTOPARENT,$out/share,g" \
      -e "s,\$SELFAUTOGRANDPARENT,$out/share,g" \
      -e "/^mpost,/d" `# CVE-2016-10243` \
      -i "$TEXMFCNF/texmf.cnf"

    mkdir "$out/share/texmf-local"
  '' +
    # now filter hyphenation patterns and formats
  (let
    hyphens = lib.filter (p: p.hasHyphens or false && p.tlType == "run") pkgList.splitBin.wrong;
    hyphenPNames = sortedUniqueStrings (map (p: p.pname) hyphens);
    formats = lib.filter (p: p.hasFormats or false && p.tlType == "run") pkgList.splitBin.wrong;
    formatPNames = sortedUniqueStrings (map (p: p.pname) formats);
    # sed expression that prints the lines in /start/,/end/ except for /end/
    section = start: end: "/${start}/,/${end}/{ /${start}/p; /${end}/!p; };\n";
    script =
      writeText "hyphens.sed" (
        # document how the file was generated (for language.dat)
        "1{ s/^(% Generated by .*)$/\\1, modified by texlive.combine/; p; }\n"
        # pick up the header
        + "2,/^% from/{ /^% from/!p; };\n"
        # pick up all sections matching packages that we combine
        + lib.concatMapStrings (pname: section "^% from ${pname}:$" "^% from|^%%% No changes may be made beyond this point.$") hyphenPNames
        # pick up the footer (for language.def)
        + "/^%%% No changes may be made beyond this point.$/,$p;\n"
      );
    scriptLua =
      writeText "hyphens.lua.sed" (
        "1{ s/^(-- Generated by .*)$/\\1, modified by texlive.combine/; p; }\n"
        + "2,/^-- END of language.us.lua/p;\n"
        + lib.concatMapStrings (pname: section "^-- from ${pname}:$" "^}$|^-- from") hyphenPNames
        + "$p;\n"
      );
    fmtutilSed =
      writeText "fmtutil.sed" (
        "1{ s/^(# Generated by .*)$/\\1, modified by texlive.combine/; p; }\n"
        + "2,/^# from/{ /^# from/!p; };\n"
        + lib.concatMapStrings (pname: section "^# from ${pname}:$" "^# from") formatPNames
      );
  in ''
    for fname in "$out"/share/texmf/tex/generic/config/language.{dat,def}; do
      [[ -e "$fname" ]] && sed -E -n -f '${script}' -i "$fname"
    done
    [[ -e "$out"/share/texmf/tex/generic/config/language.dat.lua ]] && sed -E -n -f '${scriptLua}' -i "$out"/share/texmf/tex/generic/config/language.dat.lua
    [[ -e "$out"/share/texmf/web2c/fmtutil.cnf ]] && sed -E -n -f '${fmtutilSed}' -i "$out"/share/texmf/web2c/fmtutil.cnf
  '') +

  # function to wrap created executables with required env vars
  ''
    wrapBin() {
    for link in "$out"/bin/*; do
      [ -L "$link" -a -x "$link" ] || continue # if not link, assume OK
      local target=$(readlink "$link")

      # skip simple local symlinks; mktexfmt in particular
      echo "$target" | grep / > /dev/null || continue;

      echo -n "Wrapping '$link'"
      rm "$link"
      makeWrapper "$target" "$link" \
        --prefix PATH : "${gnused}/bin:${gnugrep}/bin:${coreutils}/bin:$out/bin:${perl}/bin" \
        --prefix PERL5LIB : "$PERL5LIB" \
        --set-default TEXMFCNF "$TEXMFCNF"

      # avoid using non-nix shebang in $target by calling interpreter
      if [[ "$(head -c 2 "$target")" = "#!" ]]; then
        local cmdline="$(head -n 1 "$target" | sed 's/^\#\! *//;s/ *$//')"
        local relative=`basename "$cmdline" | sed 's/^env //' `
        local newInterp=`echo "$relative" | cut -d\  -f1`
        local params=`echo "$relative" | cut -d\  -f2- -s`
        local newPath="$(type -P "$newInterp")"
        if [[ -z "$newPath" ]]; then
          echo " Warning: unknown shebang '$cmdline' in '$target'"
          continue
        fi
        echo " and patching shebang '$cmdline'"
        sed "s|^exec |exec $newPath $params |" -i "$link"

      elif head -n 1 "$target" | grep -q 'exec perl'; then
        # see #24343 for details of the problem
        echo " and patching weird perl shebang"
        sed "s|^exec |exec '${perl}/bin/perl' -w |" -i "$link"

      else
        sed 's|^exec |exec -a "$0" |' -i "$link"
        echo
      fi
    done
    }
  '' +
  # texlive post-install actions
  ''
    ln -sf "$out"/share/texmf/scripts/texlive/updmap.pl "$out"/bin/updmap
  '' +
    # now hack to preserve "$0" for mktexfmt
  ''
    cp "$out"/share/texmf/scripts/texlive/fmtutil.pl "$out/bin/fmtutil"
    patchShebangs "$out/bin/fmtutil"
    sed "1s|$| -I $out/share/texmf/scripts/texlive|" -i "$out/bin/fmtutil"
    ln -sf fmtutil "$out/bin/mktexfmt"

    perl "$out"/share/texmf/scripts/texlive/mktexlsr.pl --sort "$out"/share/texmf
    texlinks "$out/bin" && wrapBin
    FORCE_SOURCE_DATE=1 fmtutil --sys --all | grep '^fmtutil' # too verbose
    #texlinks "$out/bin" && wrapBin # do we need to regenerate format links?

    # tex intentionally ignores SOURCE_DATE_EPOCH even when FORCE_SOURCE_DATE=1
    # https://salsa.debian.org/live-team/live-build/-/blob/master/examples/hooks/reproducible/0139-reproducible-texlive-binaries-fmt-files.hook.chroot#L52
    if [[ -f "$out"/share/texmf-var/web2c/tex/tex.fmt ]]
    then
      faketime $(date --utc -d@$SOURCE_DATE_EPOCH --iso-8601=seconds) tex -output-directory "$out"/share/texmf-var/web2c/tex -ini -jobname=tex -progname=tex tex.ini
    fi
    if [[ -f "$out"/share/texmf-var/web2c/luahbtex/lualatex.fmt ]]
    then
      faketime $(date --utc -d@$SOURCE_DATE_EPOCH --iso-8601=seconds) luahbtex --output-directory="out"/share/texmf-var/web2c/luahbtex -ini -jobname=lualatex -progname=lualatex lualatex.ini
    fi

    # Disable unavailable map files
    echo y | updmap --sys --syncwithtrees --force
    # Regenerate the map files (this is optional)
    updmap --sys --force

    # sort entries to improve reproducibility
    [[ -f "$TEXMFSYSCONFIG"/web2c/updmap.cfg ]] && sort -o "$TEXMFSYSCONFIG"/web2c/updmap.cfg "$TEXMFSYSCONFIG"/web2c/updmap.cfg

    perl "$out"/share/texmf/scripts/texlive/mktexlsr.pl --sort "$out"/share/texmf-* # to make sure
  '' +
    # install (wrappers for) scripts, based on a list from upstream texlive
  ''
    source '${bin.core.out}/share/texmf-dist/scripts/texlive/scripts.lst'
    for s in $texmf_scripts; do
      [[ -x "$out/share/texmf/scripts/$s" ]] || continue
      tName="$(basename $s | sed 's/\.[a-z]\+$//')" # remove extension
      [[ ! -e "$out/bin/$tName" ]] || continue
      ln -sv "$(realpath $out/share/texmf/scripts/$s)" "$out/bin/$tName" # wrapped below
    done
  '' +
    # A hacky way to provide repstopdf
    #  * Copy is done to have a correct "$0" so that epstopdf enables the restricted mode
    #  * ./bin/repstopdf needs to be a symlink to be processed by wrapBin
  ''
    if [[ -e "$out"/bin/epstopdf ]]; then
      cp "$out"/bin/epstopdf "$out"/share/texmf/scripts/repstopdf
      ln -s "$out"/share/texmf/scripts/repstopdf "$out"/bin/repstopdf
    fi
  '' +
    # finish up the wrappers
  ''
    rm "$out"/bin/*-sys
    wrapBin
  '' +
    # Perform a small test to verify that the restricted mode get enabled when
    # needed (detected by checking if it disallows --gscmd)
  ''
    if [[ -e "$out"/bin/epstopdf ]]; then
      echo "Testing restricted mode for {,r}epstopdf"
      ! (epstopdf --gscmd echo /dev/null 2>&1 || true) | grep forbidden
      (repstopdf --gscmd echo /dev/null 2>&1 || true) | grep forbidden
    fi
  '' +
  # TODO: a context trigger https://www.preining.info/blog/2015/06/debian-tex-live-2015-the-new-layout/
    # http://wiki.contextgarden.net/ConTeXt_Standalone#Unix-like_platforms_.28Linux.2FMacOS_X.2FFreeBSD.2FSolaris.29

    # I would just create links from "$out"/share/{man,info},
    #   but buildenv has problems with merging symlinks with directories;
    #   note: it's possible we might need deepen the work-around to man/*.
  ''
    for d in {man,info}; do
      [[ -e "$out/share/texmf/doc/$d" ]] || continue;
      mkdir -p "$out/share/$d"
      ln -s -t "$out/share/$d" "$out/share/texmf/doc/$d"/*
    done
  '' +
  # MkIV uses its own lookup mechanism and we need to initialize
  # caches for it.
  ''
    if [[ -e "$out/bin/mtxrun" ]]; then
      mtxrun --generate
    fi
  ''
    + bin.cleanBrokenLinks +
  # Get rid of all log files. They are not needed, but take up space
  # and render the build unreproducible by their embedded timestamps.
  ''
    find $TEXMFSYSVAR/web2c -name '*.log' -delete
  ''
  ;
}).overrideAttrs (_: { allowSubstitutes = true; })
# TODO: make TeX fonts visible by fontconfig: it should be enough to install an appropriate file
#       similarly, deal with xe(la)tex font visibility?
