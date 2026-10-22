# mentat's Python client: a small Ray-compatible shim that installs under the import name `ray`
# and talks to the box's mentatd. The spark agent uses its ray.register.connect(), and model
# engines use it in place of Ray.
{ lib, buildPythonPackage, setuptools, mentat }:

buildPythonPackage {
  pname = "mentatd";
  inherit (mentat) version;
  src = "${mentat.src}/python";
  # mentat's repository commits an old setuptools build/ tree, which upstream's .dockerignore
  # keeps out of its wheel. Every file in the store has the same mtime, so setuptools would
  # take those old modules as current and install them.
  postPatch = ''
    rm -rf build mentatd.egg-info
  '';
  pyproject = true;
  build-system = [ setuptools ];
  pythonImportsCheck = [ "ray.register" ];
  meta = {
    description = "mentat's Ray-compatible Python client";
    homepage = "https://github.com/kindlingai/mentat";
    license = with lib.licenses; [ mit asl20 ];
  };
}
