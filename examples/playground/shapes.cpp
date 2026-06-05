#include "shapes.h"

#include <cmath>
#include <sstream>

double Point::dist_to(const Point& other) const {
  const double dx = x - other.x;
  const double dy = y - other.y;
  return std::sqrt(dx * dx + dy * dy);
}

double Rectangle::width() const {
  return bottom_right.x - top_left.x;
}

double Rectangle::height() const {
  return bottom_right.y - top_left.y;
}

double Rectangle::area() const {
  return width() * height();
}

std::string Rectangle::describe() const {
  std::ostringstream os;
  os << "Rect(" << width() << "x" << height() << ", area=" << area() << ")";
  return os.str();
}

Point midpoint(const Point& a, const Point& b) {
  return Point{(a.x + b.x) / 2.0, (a.y + b.y) / 2.0};
}
