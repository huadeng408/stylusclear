// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInitializableSettlementEngine {
    function initialize(address initialAdmin, bool benchmarkSeedingEnabled) external;
    function admin() external view returns (address);
}

interface IArbWasm {
    function activateProgram(address program) external payable returns (uint16 version, uint256 dataFee);
}

/// @title StylusAtomicFactory
/// @notice Atomically deploys via front-run-proof `CREATE2`, activates Stylus WASM programs via `ArbWasm (0x71)`
///         when deployed bytecode carries the `0xEFF000` Stylus prefix, and initializes `admin()` in one transaction.
contract StylusAtomicFactory {
    address public constant ARB_WASM = address(0x0000000000000000000000000000000000000071);

    error DeploymentFailed();
    error ActivationFailed();
    error InitializationFailed();
    error RefundFailed();

    event EngineAtomicallyDeployed(
        address indexed deployedEngine,
        address indexed initialAdmin,
        bytes32 indexed guardedSalt,
        bool benchmarkSeedingEnabled,
        bool stylusActivated
    );

    function deriveGuardedSalt(address deployer, address initialAdmin, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(deployer, initialAdmin, userSalt));
    }

    function computeEngineAddress(
        bytes32 initCodeHash,
        address deployer,
        address initialAdmin,
        bytes32 userSalt
    ) external view returns (address) {
        bytes32 guardedSalt = deriveGuardedSalt(deployer, initialAdmin, userSalt);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), guardedSalt, initCodeHash)))));
    }

    function deployAndInitialize(
        bytes memory initCode,
        bytes32 userSalt,
        address initialAdmin,
        bool benchmarkSeedingEnabled
    ) external payable returns (address engine) {
        if (initCode.length == 0 || initialAdmin == address(0)) revert DeploymentFailed();
        bytes32 guardedSalt = deriveGuardedSalt(msg.sender, initialAdmin, userSalt);
        assembly {
            engine := create2(0, add(initCode, 0x20), mload(initCode), guardedSalt)
        }
        if (engine == address(0) || engine.code.length == 0) revert DeploymentFailed();

        bool stylusActivated = false;
        bytes memory deployed = engine.code;
        if (deployed.length >= 3 && deployed[0] == 0xEF && deployed[1] == 0xF0 && deployed[2] == 0x00) {
            if (ARB_WASM.code.length == 0) revert ActivationFailed();
            (, uint256 dataFee) = IArbWasm(ARB_WASM).activateProgram{value: msg.value}(engine);
            stylusActivated = true;
            if (msg.value > dataFee) {
                (bool ok, ) = msg.sender.call{value: msg.value - dataFee}("");
                if (!ok) revert RefundFailed();
            }
        } else if (msg.value > 0) {
            (bool ok, ) = msg.sender.call{value: msg.value}("");
            if (!ok) revert RefundFailed();
        }

        address curAdmin = IInitializableSettlementEngine(engine).admin();
        if (curAdmin == address(0)) {
            IInitializableSettlementEngine(engine).initialize(initialAdmin, benchmarkSeedingEnabled);
            curAdmin = IInitializableSettlementEngine(engine).admin();
        }
        if (curAdmin != initialAdmin) revert InitializationFailed();

        emit EngineAtomicallyDeployed(engine, initialAdmin, guardedSalt, benchmarkSeedingEnabled, stylusActivated);
    }
}
