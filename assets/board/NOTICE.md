# Board artwork

`board.svg` and `board.json` are the `esp32-devkit-c-v4` board from
[wokwi/wokwi-boards](https://github.com/wokwi/wokwi-boards), under the MIT
licence. `board.json` is unmodified.

**`board.svg` is modified**: its `<filter>` definitions and the 98
`filter="url(…)"` references to them were removed. `flutter_svg` does not
support filters and drops any element carrying one — which was every drawable
on the board, so it rendered as nothing at all. Without them the board draws
correctly, only without its decorative drop shadows.

`board.json` carries the pin table in millimetres, in the same coordinate space
as the SVG's `viewBox="0 0 27.9 56.6"`, which is what lets the Board screen put
a pin block exactly where its silkscreen label is.
