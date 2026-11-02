import { main } from "@nullplatform/plugin";
import { workerConfigOf } from "./config";
import { providerOf } from "./providers";
import { parametersWorker } from "./worker";

const provider = providerOf();
await main(parametersWorker(provider, workerConfigOf()));
