{ runCommand
, lib
, stdenv
, storeDir ? builtins.storeDir
, writeScript
, singularity
, writeReferencesToFile
, bash
, vmTools
, gawk
, util-linux
, runtimeShell
, e2fsprogs
}:
rec {
  shellScript = name: text:
    writeScript name ''
      #!${runtimeShell}
      set -e
      ${text}
    '';

  mkLayer =
    { name
    , contents ? [ ]
    ,
    }:
    runCommand "singularity-layer-${name}"
      {
        inherit contents;
      } ''
      mkdir $out
      for f in $contents ; do
        cp -ra $f $out/
      done
    '';

  buildImage =
    { name
    , contents ? [ ]
    , diskSize ? 1024
    , runScript ? "#!${stdenv.shell}\nexec /bin/sh"
    , runAsRoot ? null
    , memSize ? 512
    }:
    let
      layer = mkLayer {
        inherit name;
        contents = contents ++ [ bash runScriptFile ];
      };
      runAsRootFile = shellScript "run-as-root.sh" runAsRoot;
      runScriptFile = shellScript "run-script.sh" runScript;
      result = vmTools.runInLinuxVM (
        runCommand "singularity-image-${name}.img"
          {
            buildInputs = [ singularity e2fsprogs util-linux gawk ];
            layerClosure = writeReferencesToFile layer;
            preVM = vmTools.createEmptyImage {
              size = diskSize;
              fullName = "singularity-run-disk";
            };
            inherit memSize;
          }
          ''
            rm -rf $out
            mkdir disk
            mkfs -t ext3 -b 4096 /dev/${vmTools.hd}
            mount /dev/${vmTools.hd} disk
            mkdir -p disk/img
            cd disk/img
            mkdir proc sys dev

            # Run root script
            ${lib.optionalString (runAsRoot != null) ''
              mkdir -p ./${storeDir}
              mount --rbind ${storeDir} ./${storeDir}
              unshare -imnpuf --mount-proc chroot ./ ${runAsRootFile}
              umount -R ./${storeDir}
            ''}

            # Build /bin and copy across closure
            mkdir -p bin ./${builtins.storeDir}
            for f in $(cat $layerClosure) ; do
              cp -ar $f ./$f
            done

            for c in ${toString contents} ; do
              for f in $c/bin/* ; do
                if [ ! -e bin/$(basename $f) ] ; then
                  ln -s $f bin/
                fi
              done
            done

            # Create runScript and link shell
            if [ ! -e bin/sh ]; then
              ln -s ${runtimeShell} bin/sh
            fi
            mkdir -p .singularity.d
            ln -s ${runScriptFile} .singularity.d/runscript

            # Fill out .singularity.d
            mkdir -p .singularity.d/env
            touch .singularity.d/env/94-appsbase.sh

            cd ..
            mkdir -p /var/singularity/mnt/{container,final,overlay,session,source}
            echo "root:x:0:0:System administrator:/root:/bin/sh" > /etc/passwd
            echo > /etc/resolv.conf
            TMPDIR=$(pwd -P) singularity build $out ./img
          '');

    in
    result;
}
