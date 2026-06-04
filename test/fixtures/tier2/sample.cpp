// tier2/sample.cpp — deterministic member-completion fixture (Tier 2).
struct Point {
  int x;
  int y;
  double dist() const;
  void move(int dx, int dy);
};

int use(Point p) {
  int a = p.x;
  double d = p.di;
  return a;
}
