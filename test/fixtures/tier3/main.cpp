// tier3/main.cpp — deterministic goto/info fixture (Tier 3).
#include "lib.h"

struct Widget {
  int width;
  int height;
  int area() const;
};

int Widget::area() const {
  return width * height;
}

int local_helper(int x) {
  return x + 1;
}

int main() {
  Widget w;
  w.width = 3;
  w.height = 4;
  int total = compute_sum(w.area(), kAnswer);
  return local_helper(total);
}
