/* Tier 1 diagnostics fixture: a deterministic warning AND an error.
 * #warning fires during preprocessing — independent of -Wall and unaffected by
 * the later sema error (clang suppresses end-of-scope warnings like
 * unused-variable once a function has an error, so we don't rely on those).
 * The undeclared identifier is always an error regardless of flags. */
int main(void) {
	int dog = 1;
    	return 0;
}
