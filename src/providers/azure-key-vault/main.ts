import { main } from "@nullplatform/plugin";
import { workerConfigOf } from "../../config";
import { parametersWorker } from "../../worker";
import { azureKeyVault, SLUG } from "./index";

// The azure-key-vault worker over the backend's own client, with the credentials the environment holds.
await main(parametersWorker(azureKeyVault(), workerConfigOf(SLUG)));
