switch (kind) {
  case 1: run(); break;
  case 2:
  default: fallback();
}
try { risky(); } catch (error) { throw error; } finally { cleanup(); }
try { optional(); } catch {}
