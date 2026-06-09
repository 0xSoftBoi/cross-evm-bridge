import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  // the validator key authorizes destination releases; defaults to the deployer for demos
  const validator = process.env.VALIDATOR_ADDRESS || deployer.address;

  const token = await ethers.deployContract("MyToken");
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();
  console.log(`Token deployed at: ${tokenAddress}`);

  const bridge = await ethers.deployContract("Bridge", [tokenAddress, validator]);
  await bridge.waitForDeployment();
  console.log(`Bridge deployed at: ${await bridge.getAddress()} (validator ${validator})`);

  // fund the destination reserve
  await token.transfer(await bridge.getAddress(), ethers.parseEther("1000"));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
