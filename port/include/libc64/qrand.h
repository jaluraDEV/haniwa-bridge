#ifndef LQRAND_H
#define LQRAND_H

#include "types.h"

u32 qrand(void);
void sqrand(u32);
u32 qrand_get_seed(void);
void qrand_set_seed(u32);
f32 fqrand(void);
f32 fqrand2(void);

#endif