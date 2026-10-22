# vLLM with mentat's Ray-compatible client in place of Ray, as kindling-spark-os's model images
# have it (mentat's GUIDE.md: pip uninstall ray, then install the mentatd wheel). The client
# installs under the import name `ray`, so vLLM's Ray executor talks to the box's mentatd.
final: prev: {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (python-final: python-prev: {
      mentat-ray = python-final.callPackage ../pkgs/ray-shim.nix {
        mentat = final.callPackage ../pkgs/mentat-source.nix { };
      };
      vllm = python-prev.vllm.overridePythonAttrs (old: {
        dependencies = map
          (dep: if (dep.pname or "") == "ray" then python-final.mentat-ray else dep)
          old.dependencies;
        # The client's distribution is mentatd, not ray, as in the images.
        pythonRemoveDeps = (old.pythonRemoveDeps or [ ]) ++ [ "ray" ];
      });
    })
  ];
}
