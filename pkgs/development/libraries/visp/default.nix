{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  opencv,
  xorg,
  lapack,
  eigen,
  libv4l,
  zbar,
  libdc1394,
  nlohmann_json
}:

stdenv.mkDerivation rec {
  pname = "visp";
  version = "3.6.0";

  src = fetchFromGitHub {
    owner = "lagadic";
    repo = "visp";
    rev = "v${version}";
    sha256 = "sha256-m5Tmr+cZab7eSjmbXb8HpJpFHb0UYFTyimY+CkfBIAo=";
  };

  # fix to allow installing to an absolute path
  # fixed upstream at https://github.com/lagadic/visp/commit/fdda5620389badee998fe1926ddd3b46f7a6bcd8
  patches = [ ./0001-CMake-allow-absolute-install-paths.patch ];

  buildInputs = [
    opencv
    xorg.libX11
    lapack
    eigen
    libv4l
    zbar
    libdc1394
    nlohmann_json
  ];

  nativeBuildInputs = [ cmake ];

  # use `pkg-config --cflags visp` to get build flags

  meta = with lib; {
    description = "Open-source visual servoing platform";
    homepage = "https://visp.inria.fr";
    license = licenses.gpl2;
    maintainers = with maintainers; [ adob ];
    platforms = platforms.all;
  };
}
