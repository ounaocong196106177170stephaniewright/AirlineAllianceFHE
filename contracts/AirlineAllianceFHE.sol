// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract AirlineAllianceFHE is SepoliaConfig {
    struct EncryptedMember {
        uint256 memberId;
        euint32 encryptedMiles;
        euint32 encryptedAirlineCode;
        uint256 lastUpdate;
    }
    
    struct DecryptedMember {
        uint32 miles;
        string airlineCode;
        bool isRevealed;
    }

    uint256 public memberCount;
    mapping(uint256 => EncryptedMember) public encryptedMembers;
    mapping(uint256 => DecryptedMember) public decryptedMembers;
    
    mapping(string => euint32) private encryptedAirlineMiles;
    string[] private airlineCodes;
    
    mapping(uint256 => uint256) private requestToMemberId;
    
    event MemberAdded(uint256 indexed memberId, uint256 timestamp);
    event MilesTransferRequested(uint256 indexed memberId);
    event MilesTransferred(uint256 indexed memberId);
    
    modifier onlyAuthorizedAirline(uint256 memberId) {
        _;
    }
    
    function addEncryptedMember(
        euint32 encryptedMiles,
        euint32 encryptedAirlineCode
    ) public {
        memberCount += 1;
        uint256 newId = memberCount;
        
        encryptedMembers[newId] = EncryptedMember({
            memberId: newId,
            encryptedMiles: encryptedMiles,
            encryptedAirlineCode: encryptedAirlineCode,
            lastUpdate: block.timestamp
        });
        
        decryptedMembers[newId] = DecryptedMember({
            miles: 0,
            airlineCode: "",
            isRevealed: false
        });
        
        emit MemberAdded(newId, block.timestamp);
    }
    
    function requestMilesTransfer(uint256 memberId) public onlyAuthorizedAirline(memberId) {
        EncryptedMember storage member = encryptedMembers[memberId];
        require(!decryptedMembers[memberId].isRevealed, "Already processed");
        
        bytes32[] memory ciphertexts = new bytes32[](2);
        ciphertexts[0] = FHE.toBytes32(member.encryptedMiles);
        ciphertexts[1] = FHE.toBytes32(member.encryptedAirlineCode);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.processTransfer.selector);
        requestToMemberId[reqId] = memberId;
        
        emit MilesTransferRequested(memberId);
    }
    
    function processTransfer(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 memberId = requestToMemberId[requestId];
        require(memberId != 0, "Invalid request");
        
        EncryptedMember storage eMember = encryptedMembers[memberId];
        DecryptedMember storage dMember = decryptedMembers[memberId];
        require(!dMember.isRevealed, "Already processed");
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        (uint32 miles, string memory airline) = abi.decode(cleartexts, (uint32, string));
        
        dMember.miles = miles;
        dMember.airlineCode = airline;
        dMember.isRevealed = true;
        
        if (FHE.isInitialized(encryptedAirlineMiles[dMember.airlineCode]) == false) {
            encryptedAirlineMiles[dMember.airlineCode] = FHE.asEuint32(0);
            airlineCodes.push(dMember.airlineCode);
        }
        encryptedAirlineMiles[dMember.airlineCode] = FHE.add(
            encryptedAirlineMiles[dMember.airlineCode], 
            FHE.asEuint32(dMember.miles)
        );
        
        emit MilesTransferred(memberId);
    }
    
    function getMemberDetails(uint256 memberId) public view returns (
        uint32 miles,
        string memory airlineCode,
        bool isProcessed
    ) {
        DecryptedMember storage m = decryptedMembers[memberId];
        return (m.miles, m.airlineCode, m.isRevealed);
    }
    
    function getEncryptedAirlineMiles(string memory airline) public view returns (euint32) {
        return encryptedAirlineMiles[airline];
    }
    
    function requestAirlineMilesDecryption(string memory airline) public {
        euint32 miles = encryptedAirlineMiles[airline];
        require(FHE.isInitialized(miles), "Airline not found");
        
        bytes32[] memory ciphertexts = new bytes32[](1);
        ciphertexts[0] = FHE.toBytes32(miles);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptAirlineMiles.selector);
        requestToMemberId[reqId] = bytes32ToUint(keccak256(abi.encodePacked(airline)));
    }
    
    function decryptAirlineMiles(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 airlineHash = requestToMemberId[requestId];
        string memory airline = getAirlineFromHash(airlineHash);
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        uint32 totalMiles = abi.decode(cleartexts, (uint32));
    }
    
    function bytes32ToUint(bytes32 b) private pure returns (uint256) {
        return uint256(b);
    }
    
    function getAirlineFromHash(uint256 hash) private view returns (string memory) {
        for (uint i = 0; i < airlineCodes.length; i++) {
            if (bytes32ToUint(keccak256(abi.encodePacked(airlineCodes[i]))) == hash) {
                return airlineCodes[i];
            }
        }
        revert("Airline not found");
    }
    
    function calculateRedeemableMiles(euint32 encryptedMiles, euint32 conversionRate) public pure returns (euint32) {
        return FHE.div(encryptedMiles, conversionRate);
    }
    
    function combineMiles(euint32 miles1, euint32 miles2) public pure returns (euint32) {
        return FHE.add(miles1, miles2);
    }
}