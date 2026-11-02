import { main } from "@nullplatform/plugin";
import { workerConfigOf } from "../../config";
import { parametersWorker } from "../../worker";
import { hashicorpVault, SLUG } from "./index";

// The hashicorp-vault worker over the backend's own client, with the credentials the environment holds.
await main(parametersWorker(hashicorpVault(), workerConfigOf(SLUG)));
