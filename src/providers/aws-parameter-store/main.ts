import { main } from "@nullplatform/plugin";
import { parametersWorker } from "../../worker";
import { workerConfigOf } from "../../config";
import { awsParameterStore, SLUG } from "./index";

// The aws-parameter-store worker: the SDK's clients over the agent's credentials, or the role the platform names.
await main(parametersWorker(awsParameterStore(), workerConfigOf(SLUG)));
