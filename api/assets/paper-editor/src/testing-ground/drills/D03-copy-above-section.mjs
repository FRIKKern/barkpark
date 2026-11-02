import { trip } from "./trip.mjs";

export default {
  id: "D03",
  title: "Copy above its section",
  doc: trip,
  steps: [
    { say: "Hold Option and drag \"Left the car park at six.\" by its handle above \"Day one\"", hands: true },
    { say: "Type in the copy", hands: true },
  ],
  green: ["duplicate-ids", "refused-batches"],
};
