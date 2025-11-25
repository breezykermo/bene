{
  description = "Bene - An EPUB reading system with Rust backend and JavaScript frontend";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    depot = {
      url = "github:cognitive-engineering-lab/depot";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, depot }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        # Get Rust toolchain from rust-toolchain.toml
        rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

        # Get depot from its flake
        depotPkg = depot.packages.${system}.default;

        # Common dependencies for Tauri builds
        tauriBuildInputs = with pkgs; [
          gtk3
          webkitgtk_4_1
          libsoup_3
        ];

        tauriNativeBuildInputs = with pkgs; [
          pkg-config
          wrapGAppsHook4  # Ensures proper GTK environment
        ];

      in
      {
        # Default package: Desktop Tauri application
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "bene";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = [
            rustToolchain
            pkgs.cargo-tauri
            depotPkg
            pkgs.nodejs_22
            pkgs.pnpm.configHook
          ] ++ tauriNativeBuildInputs;

          buildInputs = tauriBuildInputs;

          # Fetch pnpm dependencies ahead of time for reproducibility
          pnpmDeps = pkgs.pnpm.fetchDeps {
            pname = "bene-js";
            version = "0.1.0";
            src = ./js;
            # This hash will need to be computed on first build
            hash = pkgs.lib.fakeHash;
          };

          buildPhase = ''
            runHook preBuild

            # Step 1: Generate TypeScript bindings from Rust
            # This runs a test that exports ts-rs bindings
            echo "Generating TypeScript bindings..."
            cd rs
            cargo test -p bene-epub export_bindings --release
            cp -r crates/bene-epub/bindings ../js/packages/bene-common/src/

            # Step 2: Build JavaScript packages with depot
            echo "Building frontend with depot..."
            cd ../js
            export HOME=$TMPDIR
            pnpm config set store-dir $pnpmDeps
            depot -p bene-desktop build --release

            # Step 3: Build Tauri desktop application
            echo "Building Tauri application..."
            cd ../rs
            cargo tauri build --bundles deb

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            # Install binary
            mkdir -p $out/bin
            cp rs/target/release/bene-app $out/bin/bene

            # Install desktop file
            mkdir -p $out/share/applications
            cat > $out/share/applications/bene.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Bene Reader
Comment=An EPUB reading system
Exec=$out/bin/bene %F
Icon=bene
Categories=Office;Viewer;
MimeType=application/epub+zip;
EOF

            # Install icons
            mkdir -p $out/share/icons/hicolor/128x128/apps
            if [ -f rs/crates/bene-app/icons/128x128.png ]; then
              cp rs/crates/bene-app/icons/128x128.png $out/share/icons/hicolor/128x128/apps/bene.png
            fi

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "An EPUB reading system";
            homepage = "https://github.com/nota-lang/bene";
            license = with licenses; [ mit asl20 ];
            platforms = platforms.linux;
            mainProgram = "bene";
          };
        };

        # Development shell with all tools
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # Rust toolchain (from rust-toolchain.toml)
            rustToolchain

            # Rust tools
            pkgs.cargo-tauri
            pkgs.wasm-pack

            # JavaScript tools
            pkgs.nodejs_22
            pkgs.pnpm
            depotPkg

            # Build tools
            pkgs.just

            # Development tools
            pkgs.rust-analyzer

          ] ++ tauriBuildInputs ++ tauriNativeBuildInputs;

          # Environment setup
          RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath tauriBuildInputs;

          shellHook = ''
            echo "🦀 Bene development environment"
            echo ""
            echo "Versions:"
            echo "  Rust: $(rustc --version)"
            echo "  Node: $(node --version)"
            echo "  pnpm: $(pnpm --version)"
            echo "  depot: $(depot --version)"
            echo ""
            echo "Available commands:"
            echo "  just build-native  - Build Tauri desktop app"
            echo "  just build-wasm    - Build web app"
            echo "  just dev-native    - Run desktop app in dev mode"
            echo "  just test          - Run all tests"
            echo "  just gen-bindings  - Generate TypeScript bindings"
            echo ""
            echo "Targets available:"
            rustup target list --installed | grep -E '(wasm|x86)'
          '';
        };

        # Formatter for `nix fmt`
        formatter = pkgs.nixpkgs-fmt;
      });
}
