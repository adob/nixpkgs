{ lib
, buildPythonPackage
, fetchPypi
, ruamel-base
, ruamel_yaml_clib
, isPyPy
}:

buildPythonPackage rec {
  pname = "ruamel.yaml";
  version = "0.17.16";

  src = fetchPypi {
    inherit pname version;
    sha256 = "1a771fc92d3823682b7f0893ad56cb5a5c87c48e62b5399d6f42c8759a583b33";
  };

  # Tests use relative paths
  doCheck = false;

  propagatedBuildInputs = [ ruamel-base ]
    ++ lib.optional (!isPyPy) ruamel_yaml_clib;

  pythonImportsCheck = [
    "ruamel.yaml"
    "ruamel.base"
  ];

  meta = with lib; {
    description = "YAML parser/emitter that supports roundtrip preservation of comments, seq/map flow style, and map key order";
    homepage = "https://sourceforge.net/projects/ruamel-yaml/";
    license = licenses.mit;
    maintainers = with maintainers; [ SuperSandro2000 ];
  };
}
