#ifndef FAKEIDE_PLAYGROUND_SHAPES_H
#define FAKEIDE_PLAYGROUND_SHAPES_H

#include <string>

struct Point {
  double x;
  double y;
  double dist_to(const Point& other) const;
};

struct Rectangle {
  Point top_left;
  Point bottom_right;
  double width() const;
  double height() const;
  double area() const;
  std::string describe() const;
};

// Declared in this header, defined in shapes.cpp — `<C-]>` on a call jumps
// cross-file to the .cpp definition.
Point midpoint(const Point& a, const Point& b);

#endif
