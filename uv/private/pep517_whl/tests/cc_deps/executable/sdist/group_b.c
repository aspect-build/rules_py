long group_a_tail_value(void);

long group_b_value(void) { return 20 + group_a_tail_value(); }
