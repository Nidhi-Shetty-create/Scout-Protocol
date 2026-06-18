// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EarlySupporterReward} from "../src/EarlySupporterReward.sol";

contract EarlySupporterRewardTest is Test {
    EarlySupporterReward protocol;

    address creator = address(1);

    function setUp() public {
        protocol = new EarlySupporterReward();
    }

    function testContractDeployment() public view {
        assert(address(protocol) != address(0));
    }

    function testRegisterContent() public {
        vm.deal(creator, 1 ether);

        vm.prank(creator);
        protocol.registerContent{value: 0.03 ether}(
            "My First Content",
            "QmHash123"
        );

        (
            address returnedCreator,
            ,
            ,
            uint256 supporterCount,
            uint256 poolAmount,
            ,
            ,
            ,
            ,
            
        ) = protocol.getContent(1);

        assertEq(returnedCreator, creator);
        assertEq(supporterCount, 0);
        assertEq(poolAmount, 0.03 ether);
    }

    function testSupportContent() public {
        address supporter = address(2);

        vm.deal(creator, 1 ether);
        vm.deal(supporter, 1 ether);

        vm.prank(creator);
        protocol.registerContent{value: 0.03 ether}(
            "My First Content",
            "QmHash123"
        );

        vm.prank(supporter);
        protocol.supportContent{value: 0.01 ether}(1);

        (
            ,
            ,
            ,
            uint256 supporterCount,
            uint256 poolAmount,
            ,
            ,
            ,
            ,
            
        ) = protocol.getContent(1);

        assertEq(supporterCount, 1);
        assertEq(poolAmount, 0.04 ether);

        assertTrue(protocol.hasSupportedContent(1, supporter));
    }
}
