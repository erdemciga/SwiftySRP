//
//  SRP.swift
//  SwiftySRP
//
//  Created by Sergey A. Novitsky on 09/02/2017.
//  Copyright © 2017 Flock of Files. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation
import BigInt
import CommonCrypto

// SPR Design spec: http://srp.stanford.edu/design.html

//    N    A large safe prime (N = 2q+1, where q is prime)
//    All arithmetic is done modulo N.
//
//    g    A generator modulo N
//    k    Multiplier parameter (k = H(N, g) in SRP-6a, k = 3 for legacy SRP-6)
//    s    User's salt
//    I    Username
//    p    Cleartext Password
//    H()  One-way hash function
//        ^    (Modular) Exponentiation
//    u    Random scrambling parameter
//    a,b  Secret ephemeral values
//    A,B  Public ephemeral values
//    x    Private key (derived from p and s)
//    v    Password verifier

//    The host stores passwords using the following formula:
//    x = H(s, p)               (s is chosen randomly)
//    v = g^x                   (computes password verifier)
//    The host then keeps {I, s, v} in its password database. The authentication protocol itself goes as follows:
//    User -> Host:  I, A = g^a                  (identifies self, a = random number)
//    Host -> User:  s, B = kv + g^b             (sends salt, b = random number)
//
//    Both:  u = H(A, B)
//
//    User:  x = H(s, p)                 (user enters password)
//    NOTE: BouncyCastle does it differently because of the user name involved: 
//           x = H(s | H(I | ":" | p))  (| means concatenation)
//
//    User:  S = (B - kg^x) ^ (a + ux)   (computes session key)
//    User:  K = H(S)
//
//    Host:  S = (Av^u) ^ b              (computes session key)
//    Host:  K = H(S)
//    Now the two parties have a shared, strong session key K. To complete authentication, they need to prove to each other that their keys match. One possible way:
//    User -> Host:  M = H(H(N) xor H(g), H(I), s, A, B, K)
//    Host -> User:  H(A, M, K)
//    The two parties also employ the following safeguards:
//    The user will abort if he receives B == 0 (mod N) or u == 0.
//    The host will abort if it detects that A == 0 (mod N).
//    The user must show his proof of K first. If the server detects that the user's proof is incorrect, it must abort without showing its own proof of K.

public typealias DigestFunc = (Data) -> Data
public typealias HMacFunc = (Data, Data) -> Data
public typealias PrivateValueFunc = (BigUInt) -> BigUInt

public struct SRP
{
    /// A large safe prime per SRP spec.
    let N: BigUInt
    
    /// A generator modulo N
    let g: BigUInt
    
    /// Hash function to be used.
    let digest: DigestFunc
    
    let hmac: HMacFunc
    
    /// Function to calculate parameter a (per SRP spec above)
    private let a: PrivateValueFunc
    
    /// Function to calculate parameter b (per SRP spec above)
    private let b: PrivateValueFunc
    
    
    init(N: BigUInt,
         g: BigUInt,
         digest: @escaping DigestFunc = SRP.sha256DigestFunc,
         hmac: @escaping HMacFunc = SRP.sha256HMacFunc,
         a: @escaping PrivateValueFunc = SRP.generatePrivateValue,
         b: @escaping PrivateValueFunc = SRP.generatePrivateValue)
    {
        self.N = N
        self.g = g
        self.digest = digest
        self.a = a
        self.b = b
        self.hmac = hmac
    }
    
    /// SHA256 hash function
    public static let sha256DigestFunc: DigestFunc = { (data: Data) in
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(Array<UInt8>(data), CC_LONG(data.count), &hash)
        return Data(hash)
    }
    
    /// SHA512 hash function
    public static let sha512DigestFunc: DigestFunc = { (data: Data) in
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_SHA512(Array<UInt8>(data), CC_LONG(data.count), &hash)
        return Data(hash)
    }
    
    public static let sha256HMacFunc: HMacFunc = { (key, data) in
        var result: [UInt8] = Array(repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes, key.count, dataBytes, data.count, &result)
            }
        }
        
        return Data(result)
    }

    public static let sha512HMacFunc: HMacFunc = { (key, data) in
        var result: [UInt8] = Array(repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), keyBytes, key.count, dataBytes, data.count, &result)
            }
        }
        
        return Data(result)
    }

    
    public static func generatePrivateValue(N: BigUInt) -> BigUInt
    {
        let minBits = N.width / 2
        var random = BigUInt.randomIntegerLessThan(N)
        while (random.width < minBits)
        {
            random = BigUInt.randomIntegerLessThan(N)
        }
        
        return random
    }

    
    // TODO: Handle errors.
    public func generateClientCredentials(s: Data, I: Data, p: Data) -> (x: BigUInt, a: BigUInt, A: BigUInt)
    {
        let value_x = x(s: s, I: I, p: p)
        let value_a = a(self.N)

        // A = g^a
        let value_A = g.power(a(N), modulus: N)
        
        return (value_x, value_a, value_A)
    }
    
    public func generateServerCredentials(v: BigUInt) -> (b: BigUInt, B: BigUInt)
    {
        let k = calculate_k()
        let value_b = b(self.N)
        // B = kv + g^b
        let value_B = (((k * v) % self.N) + g.power(value_b, modulus: self.N)) % self.N
        
        return (value_b, value_B)
    }
    
    public func verifier(s: Data, I: Data,  p: Data) -> BigUInt
    {
        let valueX = x(s:s, I:I, p:p)
        
        return self.g.power(valueX, modulus:self.N)
    }
    
    public func calculateClientSecret(a: BigUInt, A:BigUInt, x: BigUInt, serverB: BigUInt) throws -> BigUInt
    {
        let value_B = try validatePublicValue(N: self.N, val: serverB)
        let value_u = hashPaddedPair(digest: self.digest, N: N, n1: A, n2: value_B)
        
        let k = calculate_k()

        // S = (B - kg^x) ^ (a + ux)
        
        let exp = ((value_u * x) + a) % self.N
        
        let tmp = (self.g.power(x, modulus: self.N) * k) % self.N
        
        // Will subtraction always be positive here?
        // Apparently, yes: https://groups.google.com/forum/#!topic/clipperz/5H-tKD-l9VU
        let S = ((value_B - tmp) % self.N).power(exp, modulus: self.N)
        
        return S
    }
    
    public func calculateServerSecret(clientA: BigUInt, v:BigUInt, b:BigUInt, B: BigUInt) throws -> BigUInt
    {
        let value_A = try validatePublicValue(N: self.N, val: clientA)
        let value_u = hashPaddedPair(digest: self.digest, N: N, n1: value_A, n2: B)
        
        // S = (Av^u) ^ b
        let S = ((value_A * v.power(value_u, modulus: self.N)) % self.N).power(b, modulus: self.N)
        
        return S
    }

    public func calculate_k() -> BigUInt
    {
        // k = H(N, g)
        return hashPaddedPair(digest: self.digest, N: self.N, n1: self.N, n2: self.g)
    }
    
    
    /// Compute the client evidence message.
    /// NOTE: This is different from the spec. above and is done the BouncyCastle way:
    /// M = H( pA | pB | pS), where pA, pB, and pS - padded values of A, B, and S
    /// - Parameters:
    ///   - a: Private ephemeral value a (per spec. above)
    ///   - A: Public ephemeral value A (per spec. above)
    ///   - x: Identity hash (computed the BouncyCastle way)
    ///   - serverB: Server public ephemeral value B (per spec. above)
    /// - Returns: The evidence message to be sent to the server.
    /// - Throws: TODO
    public func clientEvidenceMessage(a: BigUInt, A:BigUInt, x: BigUInt, serverB: BigUInt) throws -> BigUInt
    {
        let value_B = try validatePublicValue(N: self.N, val: serverB)
        let S = try calculateClientSecret(a: a, A: A, x: x, serverB: serverB)
        
        // TODO: Check if values are valid.
        return hashPaddedTriplet(digest: self.digest, N: self.N, n1: A, n2: value_B, n3: S);
    }
    
    
    /// Compute the server evidence message.
    /// NOTE: This is different from the spec above and is done the BouncyCastle way:
    /// M = H( pA | pMc | pS), where pA is the padded A value; pMc is the padded client evidence message, and pS is the padded shared secret.
    /// - Parameters:
    ///   - clientA: Client value A
    ///   - v: Password verifier v (per spec above)
    ///   - b: Private ephemeral value b
    ///   - B: Public ephemeral value B
    ///   - clientM: Client evidence message
    /// - Returns: The computed server evidence message.
    /// - Throws: TODO
    public func serverEvidenceMessage(clientA: BigUInt, v:BigUInt, b:BigUInt, B: BigUInt, clientM: BigUInt) throws -> BigUInt
    {
        // TODO: Check if values are valid.
        // M2 = SRP6Util.calculateM2(digest, N, A, M1, S);
        let value_A = try validatePublicValue(N: self.N, val: clientA)
        let S = try calculateServerSecret(clientA: clientA, v: v, b: b, B: B)
        
        return hashPaddedTriplet(digest: self.digest, N: self.N, n1: value_A, n2: clientM, n3: S);
    }
    
    public func verifyClientEvidenceMessage(a: BigUInt, A:BigUInt, x: BigUInt, B: BigUInt, clientM: BigUInt) throws -> Bool
    {
        // TODO: Check values.
        let M = try clientEvidenceMessage(a: a, A: A, x: x, serverB: B)
        return (M == clientM)
    }
    
    public func calculateSharedKey(S: BigUInt) -> BigUInt
    {
        // TODO: Check if data is valid.
        let padLength = (N.width + 7) / 8
        let paddedS = pad(S.serialize(), to: padLength)
        let hash = digest(paddedS)
        
        return BigUInt(hash)
    }
    
    public func calculateSharedKey(salt: Data, S: Data) throws -> Data
    {
        return self.hmac(salt, S)
    }
    
    private func hashPaddedPair(digest: DigestFunc, N: BigUInt, n1: BigUInt, n2: BigUInt) -> BigUInt
    {
        let padLength = (N.width + 7) / 8
        
        let paddedN1 = pad(n1.serialize(), to: padLength)
        let paddedN2 = pad(n2.serialize(), to: padLength)
        var dataToHash = Data(capacity: paddedN1.count + paddedN2.count)
        dataToHash.append(paddedN1)
        dataToHash.append(paddedN2)
        
        let hash = digest(dataToHash)
        
        return BigUInt(hash) % N
    }
    
    private func hashPaddedTriplet(digest: DigestFunc, N: BigUInt, n1: BigUInt, n2: BigUInt, n3: BigUInt) -> BigUInt
    {
        let padLength = (N.width + 7) / 8
        
        let paddedN1 = pad(n1.serialize(), to: padLength)
        let paddedN2 = pad(n2.serialize(), to: padLength)
        let paddedN3 = pad(n3.serialize(), to: padLength)
        var dataToHash = Data(capacity: paddedN1.count + paddedN2.count + paddedN3.count)
        dataToHash.append(paddedN1)
        dataToHash.append(paddedN2)
        dataToHash.append(paddedN3)
        let hash = digest(dataToHash)
        
        return BigUInt(hash) % N
    }
    
    private func validatePublicValue(N: BigUInt, val: BigUInt) throws -> BigUInt
    {
        let checkedVal = val % N
        if checkedVal == 0
        {
            // TODO: Throw error.
        }
        return checkedVal
    }
    
    private func pad(_ data: Data, to length: Int) -> Data
    {
        if data.count >= length
        {
            return data
        }
        
        var padded = Data(count: length - data.count)
        padded.append(data)
        return padded
    }
    
    
    /// Calculate the value x the BouncyCastle way: x = H(s | H(I | ":" | p))
    /// | stands for concatenation
    /// - Parameters:
    ///   - s: SRP salt
    ///   - I: User name
    ///   - p: password
    /// - Returns: SRP value x calculated as x = H(s | H(I | ":" | p)) (where H is the configured hash function)
    func x(s: Data, I: Data,  p: Data) -> BigUInt
    {
        var identityData = Data(capacity: I.count + 1 + p.count)
        
        identityData.append(I)
        identityData.append(":".data(using: .utf8)!)
        identityData.append(p)
        
        let identityHash = digest(identityData)
        
        var xData = Data(capacity: s.count + identityHash.count)
        
        xData.append(s)
        xData.append(identityHash)
        
        let xHash = digest(xData)
        let x = BigUInt(xHash) % N
        
        return x
    }
    
    
}

extension UnicodeScalar
{
    var hexNibble:UInt8
    {
        let value = self.value
        if 48 <= value && value <= 57 {
            return UInt8(value - 48)
        }
        else if 65 <= value && value <= 70 {
            return UInt8(value - 55)
        }
        else if 97 <= value && value <= 102 {
            return UInt8(value - 87)
        }
        fatalError("\(self) not a legal hex nibble")
    }
}


extension Data
{
    init(hex:String)
    {
        let scalars = hex.unicodeScalars
        var bytes = Array<UInt8>(repeating: 0, count: (scalars.count + 1) >> 1)
        for (index, scalar) in scalars.enumerated()
        {
            var nibble = scalar.hexNibble
            if index & 1 == 0 {
                nibble <<= 4
            }
            bytes[index >> 1] |= nibble
        }
        self = Data(bytes: bytes)
    }
    
    func hex() -> String
    {
        var result = String()
        result.reserveCapacity(self.count * 2)
        [UInt8](self).forEach { (aByte) in
            result += String(format: "%02X", aByte)
        }
        return result
    }
}


