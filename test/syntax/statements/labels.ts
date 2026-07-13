outer: for (let index = 0; index < 10; index++) {
    if (index === 3) continue outer;
    if (index === 7) break outer;
}

done: {
    break done;
}
