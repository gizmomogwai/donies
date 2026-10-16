namespace :nix do
  desc "Regenerate dub-lock.json from dub.selections.json (run after changing dependencies)"
  task :lock do
    sh "nix run nixpkgs#dub-to-nix > dub-lock.json"
  end

  desc "Build the flake"
  task :build do
    sh "nix build -L .#default"
  end

  desc "Build the flake and run the resulting binary"
  task test: :build do
    sh "./result/bin/donie --help"
  end

  desc "Update flake.lock"
  task :update do
    sh "nix flake update"
  end
end
