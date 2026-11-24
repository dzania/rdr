# rdr


Small PDF reader inside the terminal utilizing Kitty graphics protocol if you know zathura then you should feel at home.
## Installation

rdr runs on macOS. It needs a terminal that supports the kitty graphics protocol, such as kitty or Ghostty.

### Nix

Run it without installing:

```sh
nix run github:dzania/rdr -- paper.pdf
```

Install it into your profile (on older Nix the subcommand is `nix profile install`):

```sh
nix profile add github:dzania/rdr
```

Or add it to a nix-darwin flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    rdr.url = "github:dzania/rdr";
    rdr.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nix-darwin, rdr, ... }: {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    rdr.url = "github:dzania/rdr";
    rdr.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nix-darwin, rdr, ... }: {
    darwinConfigurations.my-mac = nix-darwin.lib.darwinSystem {
      modules = [
        ({ pkgs, ... }: {
          environment.systemPackages = [
            rdr.packages.${pkgs.stdenv.hostPlatform.system}.default
          ];
        })
      ];
    };
  };
}
```

With Home Manager, put the same package in `home.packages`.

To build from a checkout:

```sh
nix build
./result/bin/rdr paper.pdf
```

### From source

You need Zig 0.17 and MuPDF from Homebrew:

```sh
brew install mupdf
zig build --release=safe
./zig-out/bin/rdr paper.pdf
```

## Usage

```sh
rdr <file> [page]
```

`page` is 1-based.

## Keybindings

### Document

| Key | Action |
| --- | --- |
| `j` / `k` | Scroll down / up |
| `h` / `l` | Scroll left / right |
| `d` / `u` | Half a screen down / up |
| `J` / `Space` | Next page |
| `K` / `b` | Previous page |
| `gg` / `G` | First / last page |
| `+` / `-` | Zoom in / out |
| `=` | Fit width |
| `Tab` | Open the index |
| `Esc` | Clear the selection |
| `q` / `Ctrl-c` | Quit |

The mouse wheel scrolls. Drag to select text; when you release, rdr copies it to the clipboard through OSC 52, which kitty allows by default and which also works over SSH.

### Index

| Key | Action |
| --- | --- |
| `j` / `k` | Move down / up |
| `l` | Expand the entry |
| `h` | Collapse the entry, or move to its parent |
| `L` / `H` | Expand / collapse all |
| `gg` / `G` | First / last entry |
| `Enter` / `Space` | Jump to the entry |
| `Tab` / `Esc` | Close the index |
| `q` / `Ctrl-c` | Quit |

## Roadmap

These are the steps toward zathura parity. Checked items work today.

- [x] Vim-style scrolling and page navigation
- [x] Zoom and fit to width
- [x] Index (table of contents)
- [x] Mouse text selection with copy to clipboard
- [ ] Search: `/`, `?`, `n`, `N`
- [ ] Count prefixes: `10G`, `5j`
- [ ] Follow links (`f`) and show link targets (`F`)
- [ ] Jump list: `Ctrl-o`, `Ctrl-i`
- [ ] Marks: `m{a-z}` to set, `'{a-z}` to jump
- [ ] Best-fit zoom (`a`) and zathura's fit width key (`s`)
- [ ] Rotation (`r`)
- [ ] Recolor for dark mode (`Ctrl-r`)
- [ ] Dual-page view
- [ ] Reload on file change, automatic and with `R`
- [ ] Remember the last page of each file
- [ ] Bookmarks
- [ ] Command line (`:`) with `:open`, `:goto`, and `:info`
- [ ] Config file with remappable keys
- [ ] Password-protected PDFs
- [ ] Presentation mode
- [ ] Test and document the other formats MuPDF opens (EPUB, XPS, CBZ)
- [ ] SyncTeX
- [ ] Linux support (input wait currently uses kqueue)
