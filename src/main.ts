import { main } from "@nullplatform/plugin";
import { workerConfigOf } from "./config";
import { allProviders } from "./providers";
import { parametersWorker } from "./worker";

await main(parametersWorker(allProviders(), workerConfigOf()));
