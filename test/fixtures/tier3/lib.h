#ifndef FAKEIDE_TIER3_LIB_H
#define FAKEIDE_TIER3_LIB_H

// Function declared in a header so goto must jump cross-file.
int compute_sum(int a, int b);

// A simple variable for the same cross-file behaviour.
extern int kAnswer;

#endif
