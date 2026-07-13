if (ready) work(); else wait();
while (pending) { if (done) break; continue; }
do { tick(); } while (active);
for (let index = 0; index < limit; index += 1) visit(index);
for (const key in object) use(key);
for (const value of values) use(value);
for await (const chunk of stream) use(chunk);
