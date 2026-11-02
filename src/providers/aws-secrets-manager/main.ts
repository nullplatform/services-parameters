import { main } from "@nullplatform/plugin";
import { parametersWorker } from "../../worker";
import { workerConfigOf } from "../../config";
import { awsSecretsManager, SLUG } from "./index";

// The aws-secrets-manager worker: the SDK's clients over the agent's credentials, or the role the platform names.
await main(parametersWorker(awsSecretsManager(), workerConfigOf(SLUG)));
