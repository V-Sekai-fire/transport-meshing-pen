# transport-meshing-pen

The meshing pen: an XR project where a person draws a character and outfit with their hands, wears it, and moves in it where others see it.

## What it is for

It is the hand end of the loop: strokes, pinch and world-grab, and the controller bindings, with the stage code running as sandbox guest programs the project loads. RFD 2262 owns the design and its releases.

## Build and run

```sh
elixir tools/build.exs
```

It builds the guest programs from the goal manifest's sibling checkouts and runs the project's gates. Open the project in a double-precision engine editor to run it.

## Licence

MIT; see `LICENSE`. Contributors are listed in `.all-contributorsrc`.
