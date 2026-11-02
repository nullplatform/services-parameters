import { main } from "@nullplatform/plugin";
import { workerConfigOf } from "../../config";
import { parametersWorker } from "../../worker";
import { gcpSecretManager, SLUG } from "./index";

// The gcp-secret-manager worker over the backend's own client, with the credentials the environment holds.
await main(parametersWorker(gcpSecretManager(), workerConfigOf(SLUG)));
