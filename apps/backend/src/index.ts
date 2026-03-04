import { startServer } from "./server.js";

startServer().catch((error) => {
  // eslint-disable-next-line no-console
  console.error(error);
  process.exit(1);
});
