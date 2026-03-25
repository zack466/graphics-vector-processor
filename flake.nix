{
  description = "VHDL Simulation Environment using custom GHDL";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    
    # local GHDL flake
    ghdl-custom.url = "git+file:/Users/zack4/forks/ghdl";
  };

  outputs = { self, nixpkgs, ghdl-custom }: 
    let
      # Assuming you are testing this on the same Apple Silicon machine
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        name = "vhdl-sim-env";

        buildInputs = [
          # Pulls the compiled, wrapped binary from your GHDL flake's package output
          ghdl-custom.packages.${system}.default
          
          # Standard tools for a VHDL workflow
          pkgs.gnumake
          pkgs.gtkwave
        ];

        shellHook = ''
          echo "========================================================"
          echo "VHDL Simulation Environment Ready!"
          echo "Using local GHDL from: $(which ghdl)"
          echo "--------------------------------------------------------"
          ghdl --version | head -n 2
          echo "========================================================"
        '';
      };
    };
}
