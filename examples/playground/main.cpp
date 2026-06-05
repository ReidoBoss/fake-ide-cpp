// fake-ide playground. Try it with:
//
//     vim80 examples/playground/main.cpp
//
// Things to try (each exercises a different tier):
//
//   Tier 1 — diagnostics:
//     * Save the file (`:w`). It compiles cleanly: no signs in the gutter.
//     * Break a line, e.g. change `Point origin{0.0, 0.0};` to
//       `Point origin{0.0,;` and `:w`. A red `E>` sign appears on that line
//       within a beat; `]d` / `[d` jump between diagnostics; the message
//       echoes on the command line when the cursor sits on the bad line.
//
//   Tier 2 — semantic completion (`omnifunc` via clang):
//     * In insert mode after `origin.`, press `<C-x><C-o>`. The popup lists
//       `x`, `y`, `dist_to` — with types in the menu column.
//     * After `r.`, the menu shows `top_left`, `bottom_right`, `width`,
//       `height`, `area`, `describe`.
//     * After `std::`, you get the namespace's members (it's a lot — clang
//       filters by what you type, so `std::str` narrows it).
//
//   Tier 3 — go-to-definition + type info:
//     * Cursor on `midpoint` (line ~30): `<C-]>` jumps cross-file to
//       `shapes.cpp` where it's defined. `<C-t>` jumps back.
//     * Cursor on `r.area()`: `<C-]>` jumps to the `Rectangle::area`
//       definition (cross-file too).
//     * Cursor on `dist_to`: press `K` (or `:FakeIdeInfo`) — the signature
//       echoes on the command line.
//
//   :FakeIdeStatus / :FakeIdeFlags — see how fake-ide resolved compile flags
//   for this file (it found `.fakeide` next door).

#include "shapes.h"

#include <iostream>
#include <vector>

int main() {
  Point origin{0.0, 0.0};
  Point target{3.0, 4.0};
  std::cout << "distance: " << origin.dist_to(target) << "\n";
  Rectangle r{Point{0.0, 0.0}, Point{10.0, 5.0}};
  std::cout << r.describe() << "\n";

  const Point m = midpoint(origin, target);
  std::cout << "midpoint: (" << m.x << ", " << m.y << ")\n";
  std::vector<Point> pts{origin, target, m};
  std::cout << "points: " << pts.size() << "\n";
  return 0;
}
