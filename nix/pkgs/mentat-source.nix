# The mentat release in kindling-spark-os's Dockerfile images. Its tag is annotated, so the commit
# it points at is pinned, not the tag, which can move.
{ fetchFromGitHub }:

{
  version = "0.21.0";
  src = fetchFromGitHub {
    owner = "kindlingai";
    repo = "mentat";
    rev = "950cabaf6b016beb71d2a5a0437df4f172576814";
    hash = "sha256-/bB/ZzhN7AdmRMd44pYJKNuWecwkZ4ESRDUkZSpGmv4=";
  };
}
