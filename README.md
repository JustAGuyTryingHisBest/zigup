# zigup
A zig version manager akin to Haskell's ghcup.

## but why?
yes, nix exists. yes, there are alternatives to this. This is more of a learning exercise and to scratch an itch than a product that I intend to have folks use.
yes, the tui code is mostly slop but again use at your own risk.
It works on macos and linux. I do not have the patience for windows so beware.

This could be extended to integrate with github's to pull down zls releases but I'm punting that for now.

## Layout
Pretty self explanatory.
Each cli subcommand has it's own module with it's own "main" function.
There are a few modules for the TUI and the TUI uses the subcommand code as a library.
