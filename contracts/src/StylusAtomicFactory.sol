// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInitializableSettlementEngine {
    function initialize(address initialAdmin, bool benchmarkSeedingEnabled) external;
    function admin() external view returns (address);
}

/// @title StylusAtomicFactory
/// @notice Eliminates any uninitialized front-running window (`D-33`) by atomically deploying via `CREATE2`
///         (or wrapping a pre-activated Stylus program in the same multicall/script tx) and verifying `admin()`.
contract StylusAtomicFactory {
    error DeploymentFailed();
    error InitializationFailed();

    event EngineAtomicallyDeployed(
        address indexed deployedEngine,
        address indexed initialAdmin,
        bytes32 indexed salt,
        bool benchmarkSeedingEnabled
    );

    function deployAndInitialize(
        bytes memory initCode,
        bytes32 salt,
        address initialAdmin,
        bool benchmarkSeedingEnabled
    ) external returns (address engine) {
        if (initCode.length == 0 || initialAdmin == address(0)) revert DeploymentFailed();
        assembly {
            engine := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (engine == address(0) || engine.code.length == 0) revert DeploymentFailed();

        address curAdmin = IInitializableSettlementEngine(engine).admin();
        if (curAdmin == address(0)) {
            IInitializableSettlementEngine(engine).initialize(initialAdmin, benchmarkSeedingEnabled);
            curAdmin = IInitializableSettlementEngine(engine).admin();
        }
        if (curAdmin != initialAdmin) revert InitializationFailed();

        emit EngineAtomicallyDeployed(engine, initialAdmin, salt, benchmarkSeedingEnabled);
    }
}
