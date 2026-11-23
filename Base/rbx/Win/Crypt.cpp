#include "rbx/Crypt.h"
#include "../SigningPublicKey.h"

#include <algorithm>
#include <stdexcept>
#include <vector>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "crypt32.lib")

namespace
{
	std::vector<BYTE> decodeBase64(const char* text, DWORD length, DWORD flags)
	{
		DWORD size = 0;
		if (!CryptStringToBinaryA(text, length, flags, NULL, &size, NULL, NULL) || size == 0)
			throw std::runtime_error("");

		std::vector<BYTE> result(size);
		if (!CryptStringToBinaryA(text, length, flags, result.data(), &size, NULL, NULL))
			throw std::runtime_error("");
		result.resize(size);
		return result;
	}
}

namespace RBX
{
	Crypt::Crypt()
		: context(0)
		, key(0)
	{
		const std::vector<BYTE> publicKey = decodeBase64(signingPublicKey, 0, CRYPT_STRING_BASE64HEADER);
		CERT_PUBLIC_KEY_INFO* keyInfo = NULL;
		DWORD keyInfoSize = 0;
		if (!CryptDecodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO, publicKey.data(),
			static_cast<DWORD>(publicKey.size()), CRYPT_DECODE_ALLOC_FLAG, NULL, &keyInfo, &keyInfoSize))
			throw std::runtime_error("");

		const BOOL acquired = CryptAcquireContextA(&context, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT);
		const BOOL imported = acquired && CryptImportPublicKeyInfo(context, X509_ASN_ENCODING, keyInfo, &key);
		LocalFree(keyInfo);

		if (!imported)
		{
			if (acquired)
				CryptReleaseContext(context, 0);
			throw std::runtime_error("");
		}
	}

	Crypt::~Crypt()
	{
		CryptDestroyKey(key);
		CryptReleaseContext(context, 0);
	}

	bool Crypt::verifySignatureBase64(std::string message, std::string signatureBase64)
	{
		if (message.size() > MAXDWORD || signatureBase64.empty() || signatureBase64.size() > MAXDWORD)
			throw std::runtime_error("");

		std::vector<BYTE> signature = decodeBase64(signatureBase64.data(),
			static_cast<DWORD>(signatureBase64.size()), CRYPT_STRING_BASE64);
		// CryptoAPI consumes RSA signature bytes in little-endian order.
		std::reverse(signature.begin(), signature.end());

		HCRYPTHASH hash = 0;
		if (!CryptCreateHash(context, CALG_SHA1, 0, 0, &hash))
			throw std::runtime_error("");

		const bool verified = CryptHashData(hash, reinterpret_cast<const BYTE*>(message.data()),
			static_cast<DWORD>(message.size()), 0)
			&& CryptVerifySignatureA(hash, signature.data(), static_cast<DWORD>(signature.size()), key, NULL, 0);
		CryptDestroyHash(hash);

		if (!verified)
			throw std::runtime_error("");
		return true;
	}
}
