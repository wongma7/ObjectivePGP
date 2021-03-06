//
//  PGPSecretKeyPacket.m
//  ObjectivePGP
//
//  Created by Marcin Krzyzanowski on 07/05/14.
//  Copyright (c) 2014 Marcin Krzyżanowski. All rights reserved.
//
//  A Secret-Key packet contains all the information that is found in a
//  Public-Key packet, including the public-key material, but also
//  includes the secret-key material after all the public-key fields.

#import "PGPSecretKeyPacket.h"
#import "PGPMPI.h"
#import "PGPS2K.h"
#import "PGPTypes.h"

#import "PGPLogging.h"
#import "PGPMacros.h"

#import "NSData+PGPUtils.h"
#import "PGPCryptoCFB.h"
#import "PGPCryptoUtils.h"
#import "PGPPublicKeyRSA.h"

@interface PGPPacket ()

@property (nonatomic, copy, readwrite) NSData *headerData;
@property (nonatomic, copy, readwrite) NSData *bodyData;

@end

@interface PGPSecretKeyPacket ()

@property (nonatomic, readwrite) PGPS2KUsage s2kUsage;
@property (nonatomic, readwrite) PGPS2K *s2k;
@property (nonatomic, readwrite) PGPSymmetricAlgorithm symmetricAlgorithm;
@property (nonatomic, readwrite) NSData *encryptedMPIsPartData; // after decrypt -> secretMPIArray
@property (nonatomic, readwrite) NSData *ivData;
@property (nonatomic, readwrite) NSArray *secretMPIArray; // decrypted MPI

@property (nonatomic, readwrite) BOOL wasDecrypted; // is decrypted
@end

@implementation PGPSecretKeyPacket

- (PGPPacketTag)tag {
    return PGPSecretKeyPacketTag;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ isEncrypted: %@", super.description, @(self.isEncryptedWithPassword)];
}

- (BOOL)isEncryptedWithPassword {
    if (self.wasDecrypted) {
        return NO;
    }

    return (self.s2kUsage == PGPS2KUsageEncrypted || self.s2kUsage == PGPS2KUsageEncryptedAndHashed);
}

- (nullable PGPMPI *)secretMPI:(NSString *)identifier {
    for (PGPMPI *mpi in self.secretMPIArray) {
        if ([mpi.identifier isEqual:identifier]) {
            return mpi;
        }
    }

    return nil;
}

- (PGPFingerprint *)fingerprint {
    return [super fingerprint];
}

- (nullable NSData *)export:(NSError *__autoreleasing _Nullable *)error {
    let data = [NSMutableData data];
    let publicKeyData = [super buildPublicKeyBodyData:YES];

    let secretKeyPacketData = [NSMutableData data];
    [secretKeyPacketData appendData:publicKeyData];
    [secretKeyPacketData appendData:[self buildSecretKeyDataAndForceV4:YES]];

    let headerData = [self buildHeaderData:secretKeyPacketData];
    [data appendData:headerData];
    [data appendData:secretKeyPacketData];

    // header not allways match because export new format while input can be old format
    NSAssert([secretKeyPacketData isEqualToData:self.bodyData], @"Secret key not match");
    return data;
}

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError *__autoreleasing *)error {
    NSUInteger position = [super parsePacketBody:packetBody error:error];
    //  5.5.3.  Secret-Key Packet Formats

    NSAssert(self.version == 0x04 || self.version == 0x03, @"Only Secret Key version 3 and 4 is supported. Found version %@", @(self.version));

    // One octet indicating string-to-key usage conventions
    [packetBody getBytes:&_s2kUsage range:(NSRange){position, 1}];
    position = position + 1;

    if (self.s2kUsage == PGPS2KUsageEncrypted || self.s2kUsage == PGPS2KUsageEncryptedAndHashed) {
        // moved to parseEncryptedPart:error
    } else if (self.s2kUsage != PGPS2KUsageNone) {
        // this is version 3, looks just like a V4 simple hash
        self.symmetricAlgorithm = (PGPSymmetricAlgorithm)self.s2kUsage; // this is tricky, but this is right. V3 algorithm is in place of s2kUsage of V4
        self.s2kUsage = PGPS2KUsageEncrypted;

        self.s2k = [[PGPS2K alloc] initWithSpecifier:PGPS2KSpecifierSimple hashAlgorithm:PGPHashMD5]; // not really parsed s2k
    }

    let encryptedData = [packetBody subdataWithRange:(NSRange){position, packetBody.length - position}];
    if (self.isEncryptedWithPassword) {
        position = position + [self parseEncryptedPart:encryptedData error:error];
    } else {
        position = position + [self parseUnencryptedPart:encryptedData error:error];
    }

    return position;
}

/**
 *  Encrypted algorithm-specific fields for secret keys
 *
 *  @param data Encrypted data
 *  @param error error
 *
 *  @return length
 */
- (NSUInteger)parseEncryptedPart:(NSData *)data error:(NSError *__autoreleasing *)error {
    NSUInteger position = 0;

    if (self.s2kUsage == PGPS2KUsageEncrypted || self.s2kUsage == PGPS2KUsageEncryptedAndHashed) {
        // If string-to-key usage octet was 255 or 254, a one-octet symmetric encryption algorithm
        [data getBytes:&_symmetricAlgorithm range:(NSRange){position, 1}];
        position = position + 1;

        // S2K
        self.s2k = [PGPS2K S2KFromData:data atPosition:position];
        position = position + self.s2k.length;
    }

    if (self.s2k.specifier == PGPS2KSpecifierGnuDummy) {
        self.ivData = [NSData data];
    } else if (self.s2kUsage != PGPS2KUsageNone) {
        // Initial Vector (IV) of the same length as the cipher's block size
        NSUInteger blockSize = [PGPCryptoUtils blockSizeOfSymmetricAlhorithm:self.symmetricAlgorithm];
        NSAssert(blockSize <= 16, @"invalid blockSize");
        self.ivData = [data subdataWithRange:(NSRange){position, blockSize}];
        position = position + blockSize;
    }

    // encrypted MPIs
    // checksum or hash is encrypted together with the algorithm-specific fields (mpis) (if string-to-key usage octet is not zero).
    self.encryptedMPIsPartData = [data subdataWithRange:(NSRange){position, data.length - position}];
    // position = position + self.encryptedMPIsPartData.length;

    return data.length;
}

/**
 *  Cleartext part, parse cleartext or unencrypted data
 *  Store decrypted values in secretMPI array
 *
 *  @param data packet data
 *  @param error error
 *
 *  @return length
 */
- (NSUInteger)parseUnencryptedPart:(NSData *)data error:(NSError *__autoreleasing *)error {
    NSUInteger position = 0;

    // check hash before read actual data
    // hash is physically located at the end of dataBody
    switch (self.s2kUsage) {
        case PGPS2KUsageEncryptedAndHashed: {
            // a 20-octet SHA-1 hash of the plaintext of the algorithm-specific portion.
            NSUInteger hashSize = [PGPCryptoUtils hashSizeOfHashAlhorithm:PGPHashSHA1];
            if (hashSize == NSNotFound) {
                PGPLogWarning(@"Invalid hash size");
                return 0;
            }

            let clearTextData = [data subdataWithRange:(NSRange){0, data.length - hashSize}];
            let hashData = [data subdataWithRange:(NSRange){data.length - hashSize, hashSize}];
            let calculatedHashData = [clearTextData pgp_SHA1];

            if (![hashData isEqualToData:calculatedHashData]) {
                if (error) {
                    *error = [NSError errorWithDomain:PGPErrorDomain code:PGPErrorPassphraseInvalid userInfo:@{ NSLocalizedDescriptionKey: @"Decrypted hash mismatch, invalid password." }];
                    return data.length;
                }
            }

        } break;
        default: {
            // a two-octet checksum of the plaintext of the algorithm-specific portion
            NSUInteger checksumLength = 2;
            let clearTextData = [data subdataWithRange:(NSRange){0, data.length - checksumLength}];
            let checksumData = [data subdataWithRange:(NSRange){data.length - checksumLength, checksumLength}];
            NSUInteger calculatedChecksum = [clearTextData pgp_Checksum];

            UInt16 checksum = 0;
            [checksumData getBytes:&checksum length:checksumLength];
            checksum = CFSwapInt16BigToHost(checksum);

            if (checksum != calculatedChecksum) {
                if (error) {
                    *error = [NSError errorWithDomain:PGPErrorDomain code:-1 userInfo:@{ NSLocalizedDescriptionKey: @"Decrypted hash mismatch, check password." }];
                    return data.length;
                }
            }
        } break;
    }

    // now read the actual data
    switch (self.publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmRSA:
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
        case PGPPublicKeyAlgorithmRSASignOnly: {
            // multiprecision integer (MPI) of RSA secret exponent d.
            let mpiD = [[PGPMPI alloc] initWithMPIData:data identifier:@"D" atPosition:position];
            position = position + mpiD.packetLength;

            // MPI of RSA secret prime value p.
            let mpiP = [[PGPMPI alloc] initWithMPIData:data identifier:@"P" atPosition:position];
            position = position + mpiP.packetLength;

            // MPI of RSA secret prime value q (p < q).
            let mpiQ = [[PGPMPI alloc] initWithMPIData:data identifier:@"Q" atPosition:position];
            position = position + mpiQ.packetLength;

            // MPI of u, the multiplicative inverse of p, mod q.
            let mpiU = [[PGPMPI alloc] initWithMPIData:data identifier:@"U" atPosition:position];
            position = position + mpiU.packetLength;

            self.secretMPIArray = @[mpiD, mpiP, mpiQ, mpiU];
        } break;
        case PGPPublicKeyAlgorithmDSA: {
            // MPI of DSA secret exponent x.
            let mpiX = [[PGPMPI alloc] initWithMPIData:data identifier:@"X" atPosition:position];
            position = position + mpiX.packetLength;

            self.secretMPIArray = @[mpiX];
        } break;
        case PGPPublicKeyAlgorithmElgamal:
        case PGPPublicKeyAlgorithmElgamalEncryptorSign: {
            // MPI of Elgamal secret exponent x.
            let mpiX = [[PGPMPI alloc] initWithMPIData:data identifier:@"X" atPosition:position];
            position = position + mpiX.packetLength;

            self.secretMPIArray = @[mpiX];
        } break;
        default:
            break;
    }

    return data.length;
}

/**
 *  Decrypt parsed encrypted packet
 *  Decrypt packet and store decrypted data on instance
 *  TODO: V3 support - partially supported, need testing.
 *  NOTE: Decrypted packet data should be released/forget after use
 */
- (nullable PGPSecretKeyPacket *)decryptedKeyPacket:(NSString *)passphrase error:(NSError *__autoreleasing *)error {
    PGPAssertClass(passphrase, NSString);
    NSParameterAssert(error);

    if (!self.isEncryptedWithPassword) {
        return self;
    }

    if (!self.ivData) {
        return nil;
    }

    PGPSecretKeyPacket *encryptedKey = self.copy;
    let encryptionSymmetricAlgorithm = encryptedKey.symmetricAlgorithm;

    // Keysize
    NSUInteger keySize = [PGPCryptoUtils keySizeOfSymmetricAlgorithm:encryptionSymmetricAlgorithm];
    NSAssert(keySize <= 32, @"invalid keySize");

    // Session key for password
    // producing a key to be used with a symmetric block cipher from a string of octets
    let sessionKeyData = [encryptedKey.s2k produceSessionKeyWithPassphrase:passphrase keySize:keySize];

    // Decrypted MPIs
    let decryptedData = [PGPCryptoCFB decryptData:encryptedKey.encryptedMPIsPartData sessionKeyData:sessionKeyData symmetricAlgorithm:encryptionSymmetricAlgorithm iv:encryptedKey.ivData];

    // now read mpis
    if (decryptedData) {
        [encryptedKey parseUnencryptedPart:decryptedData error:error];
        if (*error) {
            return nil;
        }
    }
    encryptedKey.wasDecrypted = YES;
    return encryptedKey;
}

#pragma mark - Decrypt

- (nullable NSData *)decryptData:(NSData *)data withPublicKeyAlgorithm:(PGPPublicKeyAlgorithm)publicKeyAlgorithm {
    switch (publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmRSA:
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
        case PGPPublicKeyAlgorithmRSASignOnly: {
            // return decrypted m
            return [PGPPublicKeyRSA privateDecrypt:data withSecretKeyPacket:self];
        } break;
        default:
            // TODO: add algorithms
            [NSException raise:@"PGPNotSupported" format:@"Algorith not supported"];
            break;
    }
    return nil;
}

#pragma mark - Private

/**
 *  Build public key data for fingerprint
 *
 *  @return public key data starting with version octet
 */
- (NSData *)buildSecretKeyDataAndForceV4:(BOOL)forceV4 {
    NSAssert(forceV4 == YES, @"Only V4 is supported");

    let data = [NSMutableData data];
    [data appendBytes:&_s2kUsage length:1];

    if (self.s2kUsage == PGPS2KUsageEncrypted || self.s2kUsage == PGPS2KUsageEncryptedAndHashed) {
        // If string-to-key usage octet was 255 or 254, a one-octet symmetric encryption algorithm
        [data appendBytes:&_symmetricAlgorithm length:1];

        // If string-to-key usage octet was 255 or 254, a string-to-key specifier.
        NSError *exportError = nil;
        let exportS2K = [self.s2k export:&exportError];
        if (exportS2K) {
            [data appendData:exportS2K];
        }
        NSAssert(!exportError, @"export failed");
    }

    if (self.s2kUsage != PGPS2KUsageNone) {
        // If secret data is encrypted (string-to-key usage octet not zero), an Initial Vector (IV) of the same length as the cipher's block size.
        // Initial Vector (IV) of the same length as the cipher's block size
        [data appendBytes:self.ivData.bytes length:self.ivData.length];
    }

    if (self.s2kUsage == PGPS2KUsageNone) {
        for (PGPMPI *mpi in self.secretMPIArray) {
            let exportMPI = [mpi exportMPI];
            if (exportMPI) {
                [data appendData:exportMPI];
            }
        }

        // append hash
        UInt16 checksum = CFSwapInt16HostToBig([data pgp_Checksum]);
        [data appendBytes:&checksum length:2];
    } else {
        // encrypted MPIs with encrypted hash
        [data appendData:self.encryptedMPIsPartData];

        // hash is part of encryptedMPIsPartData
    }

    // If the string-to-key usage octet is zero or 255, then a two-octet checksum of the plaintext of the algorithm-specific portion (sum of all octets, mod 65536).
    // This checksum or hash is encrypted together with the algorithm-specific fields
    // ---> is part of self.encryptedMPIsPartData
    // if (self.s2kUsage == PGPS2KUsageNone || self.s2kUsage == PGPS2KUsageEncrypted) {
    //    // Checksum
    //    UInt16 checksum = CFSwapInt16HostToBig([data pgp_Checksum]);
    //    [data appendBytes:&checksum length:2];
    //} else if (self.s2kUsage == PGPS2KUsageEncryptedAndHashed) {
    //    // If the string-to-key usage octet was 254, then a 20-octet SHA-1 hash of the plaintext of the algorithm-specific portion.
    //    [data appendData:[data pgp_SHA1]];
    //}

    //    } else if (self.s2kUsage != PGPS2KUsageNone) {
    //        // this is version 3, looks just like a V4 simple hash
    //        self.symmetricAlgorithm = (PGPSymmetricAlgorithm)self.s2kUsage; // this is tricky, but this is right. V3 algorithm is in place of s2kUsage of V4
    //        self.s2kUsage = PGPS2KUsageEncrypted;
    //
    //        self.s2k = [[PGPS2K alloc] init]; // not really parsed s2k
    //        self.s2k.specifier = PGPS2KSpecifierSimple;
    //        self.s2k.algorithm = PGPHashMD5;

    return [data copy];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    PGPSecretKeyPacket *copy = [super copyWithZone:zone];
    copy->_s2kUsage = self.s2kUsage;
    copy->_s2k = self.s2k;
    copy->_symmetricAlgorithm = self.symmetricAlgorithm;
    copy->_ivData = self.ivData;
    copy->_secretMPIArray = self.secretMPIArray;
    copy->_encryptedMPIsPartData = self.encryptedMPIsPartData;
    return copy;
}

@end
