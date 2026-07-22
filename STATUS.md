## Error 1 bootstrap.sh fails at dnf installation (Fixed)

```text
(base) amitbashyal@lpo-178574:~/Documents/BNL-DUNE/wire-cell-spack-build-tests$ ./bootstrap.sh 
Building WireCell SPNG Docker image

  Image:                 wirecell-spng:cuda89
  Spack reference:       v1.0.0
  wire-cell-spack ref:   master
  WireCell Toolkit ref:  spng
  Custom package.py:     false

#0 building with "default" instance using docker driver

#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 4.76kB done
#1 DONE 0.0s

#2 resolve image config for docker-image://docker.io/docker/dockerfile:1.7
#2 DONE 0.3s

#3 docker-image://docker.io/docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
#3 CACHED

#4 [internal] load metadata for docker.io/nvidia/cuda:12.4.1-devel-rockylinux9
#4 DONE 0.3s

#5 [internal] load .dockerignore
#5 transferring context: 34B done
#5 DONE 0.0s

#6 [builder  1/18] FROM docker.io/nvidia/cuda:12.4.1-devel-rockylinux9@sha256:700e6e9ae0f0bfc41d20dbd5ee823590bdeff42d34700960d8a92b7a90061aef
#6 DONE 0.0s

#7 [internal] load build context
#7 transferring context: 148B done
#7 DONE 0.0s

#8 [builder  2/18] COPY wirecell-package/package.py /tmp/wire-cell-toolkit-package.py
#8 CACHED

#9 [builder  3/18] RUN dnf --disablerepo=cuda install -y         bash         bzip2         ca-certificates         curl         file         findutils         gcc         gcc-c++         gcc-gfortran         git         gzip         hostname         make         patch         python3         python3-pip         tar         unzip         which         xz     && dnf clean all     && rm -rf /var/cache/dnf
#9 1.962 Rocky Linux 9 - BaseOS                          5.2 MB/s | 9.1 MB     00:01    
#9 5.114 Rocky Linux 9 - AppStream                       5.4 MB/s |  14 MB     00:02    
#9 6.710 Rocky Linux 9 - Extras                           55 kB/s |  17 kB     00:00    
#9 6.995 Package bash-5.1.8-6.el9_1.x86_64 is already installed.
#9 6.995 Package ca-certificates-2023.2.60_v7.0.306-90.1.el9_2.noarch is already installed.
#9 6.995 Package findutils-1:4.8.0-6.el9.x86_64 is already installed.
#9 6.995 Package gcc-11.4.1-2.1.el9.x86_64 is already installed.
#9 6.996 Package gcc-c++-11.4.1-2.1.el9.x86_64 is already installed.
#9 6.996 Package gzip-1.12-1.el9.x86_64 is already installed.
#9 6.996 Package hostname-3.23-6.el9.x86_64 is already installed.
#9 6.996 Package make-1:4.3-7.el9.x86_64 is already installed.
#9 6.996 Package python3-3.9.18-1.el9_3.1.x86_64 is already installed.
#9 6.997 Package tar-2:1.34-6.el9_1.x86_64 is already installed.
#9 7.002 Error: 
#9 7.002  Problem: problem with installed package curl-minimal-7.76.1-26.el9_3.3.x86_64
#9 7.002   - package curl-minimal-7.76.1-26.el9_3.3.x86_64 from @System conflicts with curl provided by curl-7.76.1-40.el9.x86_64 from baseos
#9 7.002   - package curl-minimal-7.76.1-40.el9.x86_64 from baseos conflicts with curl provided by curl-7.76.1-40.el9.x86_64 from baseos
#9 7.002   - conflicting requests
#9 7.002 (try to add '--allowerasing' to command line to replace conflicting packages or '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)
#9 ERROR: process "/bin/bash -o pipefail -c dnf --disablerepo=cuda install -y         bash         bzip2         ca-certificates         curl         file         findutils         gcc         gcc-c++         gcc-gfortran         git         gzip         hostname         make         patch         python3         python3-pip         tar         unzip         which         xz     && dnf clean all     && rm -rf /var/cache/dnf" did not complete successfully: exit code: 1
------
 > [builder  3/18] RUN dnf --disablerepo=cuda install -y         bash         bzip2         ca-certificates         curl         file         findutils         gcc         gcc-c++         gcc-gfortran         git         gzip         hostname         make         patch         python3         python3-pip         tar         unzip         which         xz     && dnf clean all     && rm -rf /var/cache/dnf:
6.996 Package hostname-3.23-6.el9.x86_64 is already installed.
6.996 Package make-1:4.3-7.el9.x86_64 is already installed.
6.996 Package python3-3.9.18-1.el9_3.1.x86_64 is already installed.
6.997 Package tar-2:1.34-6.el9_1.x86_64 is already installed.
7.002 Error: 
7.002  Problem: problem with installed package curl-minimal-7.76.1-26.el9_3.3.x86_64
7.002   - package curl-minimal-7.76.1-26.el9_3.3.x86_64 from @System conflicts with curl provided by curl-7.76.1-40.el9.x86_64 from baseos
7.002   - package curl-minimal-7.76.1-40.el9.x86_64 from baseos conflicts with curl provided by curl-7.76.1-40.el9.x86_64 from baseos
7.002   - conflicting requests
7.002 (try to add '--allowerasing' to command line to replace conflicting packages or '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)
------
ERROR: failed to build: failed to solve: process "/bin/bash -o pipefail -c dnf --disablerepo=cuda install -y         bash         bzip2         ca-certificates         curl         file         findutils         gcc         gcc-c++         gcc-gfortran         git         gzip         hostname         make         patch         python3         python3-pip         tar         unzip         which         xz     && dnf clean all     && rm -rf /var/cache/dnf" did not complete successfully: exit code: 1

```

## Solution to Error 1

Removed curl installation from dnf installation list. Rocky linux comes with a preinstalled curl-minimal. That should be enough for us. 



## Error 2  Ongoing

```bash
#17 [builder 11/18] RUN source "/opt/spack/share/spack/setup-env.sh"     && spack -e /opt/wirecell-env compiler find --scope env /usr     && spack -e /opt/wirecell-env compilers
#17 0.469 usage: spack compiler find [-h] [--mixed-toolchain | --no-mixed-toolchain]
#17 0.469                            [--scope {defaults,system,site,user,command_line} or env:ENVIRONMENT]
#17 0.469                            [-j JOBS]
#17 0.469                            ...
#17 0.469 spack compiler find: error: argument --scope: invalid choice: 'env' choose from:
#17 0.469     _builtin      defaults       defaults:linux         site
#17 0.469     command_line  defaults:base  env:/opt/wirecell-env
#17 0.469 
#17 ERROR: process "/bin/bash -o pipefail -c source \"${SPACK_ROOT}/share/spack/setup-env.sh\"     && spack -e /opt/wirecell-env compiler find --scope env /usr     && spack -e /opt/wirecell-env compilers" did not complete successfully: exit code: 2
------
 > [builder 11/18] RUN source "/opt/spack/share/spack/setup-env.sh"     && spack -e /opt/wirecell-env compiler find --scope env /usr     && spack -e /opt/wirecell-env compilers:
0.469 usage: spack compiler find [-h] [--mixed-toolchain | --no-mixed-toolchain]
0.469                            [--scope {defaults,system,site,user,command_line} or env:ENVIRONMENT]
0.469                            [-j JOBS]
0.469                            ...
0.469 spack compiler find: error: argument --scope: invalid choice: 'env' choose from:
0.469     _builtin      defaults       defaults:linux         site
0.469     command_line  defaults:base  env:/opt/wirecell-env
0.469 
------
ERROR: failed to build: failed to solve: process "/bin/bash -o pipefail -c source \"${SPACK_ROOT}/share/spack/setup-env.sh\"     && spack -e /opt/wirecell-env compiler find --scope env /usr     && spack -e /opt/wirecell-env compilers" did not complete successfully: exit code: 2


```

## Solution to Error 2
Remove the `--scope env /usr` from the flag.

### Warning 3 
```bash
#19 1230.4 ==> Warning: /opt/spack-cache/user/package_repos/fncqgg4/repos/spack_repo/builtin/packages/elfutils/package.py:155: spack.package.is_system_path is deprecated
#19 1738.6 ==> Warning: /opt/spack-cache/user/package_repos/fncqgg4/repos/spack_repo/builtin/packages/git/package.py:174: spack.package.is_system_path is deprecated
#19 1855.3 ==> Warning: Using download cache instead of version control
#19 1855.3   The required sources are normally checked out from a version control system, but have been archived in download cache: file:///opt/spack-cache/source/_source-cache/git//Maratyszcza/psimd.git/072586a71b55b7f8c584153d223e95687148a900.tar.gz. Spack lacks a tree hash to verify the integrity of this archive. Make sure your download cache is in a secure location.

```
## Solution to Warning 3

```text
The more important warning is:

Using download cache instead of version control

Spack expected to obtain psimd from its Git repository, but it found an archived copy in the source cache:

/opt/spack-cache/source/_source-cache/git/Maratyszcza/psimd.git/...

So instead of running a Git checkout, it unpacked the cached tarball.

The security warning:

Spack lacks a tree hash to verify the integrity of this archive

means Spack cannot cryptographically prove that the cached tarball has exactly the same source tree as the Git commit it represents. This commonly happens for Git-based dependencies whose source was cached as an archive without a recorded tree hash.

For your Docker build, this is generally acceptable when:

/opt/spack-cache is created and controlled by your own build process.
The cache is not writable by untrusted users.
You trust the previous Docker or BuildKit cache layer that produced it.

It becomes a concern when the cache is shared among multiple users or imported from an unknown source.

To force Spack to fetch directly from version control instead of reusing cached sources, clear the relevant cache before rebuilding:

docker builder prune

or remove the Spack source cache in the Docker build:

RUN rm -rf /opt/spack-cache/source

That will increase network traffic and build time.

A better reproducibility approach is to keep the cache trusted and pin:

the Spack version,
spack.lock,
the wire-cell-spack commit,
the SPNG source commit.
```

