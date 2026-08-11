/* A shebang interpreter cannot observe the wrapper-supplied argv[0]. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *expected_flag = getenv("CC_TEST_EXPECT_FLAG");
    int saw_expected_flag = expected_flag == NULL;
    for (int i = 1; i < argc; i++) {
        if (expected_flag != NULL && strcmp(argv[i], expected_flag) == 0) {
            saw_expected_flag = 1;
        }
        if (strcmp(argv[i], "--version") == 0) {
            if (!saw_expected_flag) {
                fprintf(stderr, "expected flag was not preserved\n");
                return 1;
            }
            puts(argv[0]);
            return 0;
        }
    }
    fprintf(stderr, "unexpected fake-driver invocation\n");
    return 1;
}
