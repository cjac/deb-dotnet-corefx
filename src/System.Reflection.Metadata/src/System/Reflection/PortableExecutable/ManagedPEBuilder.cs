// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using System.Collections.Generic;
using System.Collections.Immutable;
using System.Diagnostics;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;

namespace System.Reflection.PortableExecutable
{
    internal class ManagedPEBuilder : PEBuilder
    {
        public const int ManagedResourcesDataAlignment = ManagedTextSection.ManagedResourcesDataAlignment;
        public const int MappedFieldDataAlignment = ManagedTextSection.MappedFieldDataAlignment;

        private const int DefaultStrongNameSignatureSize = 128;

        private const string TextSectionName = ".text";
        private const string ResourceSectionName = ".rsrc";
        private const string RelocationSectionName = ".reloc";

        private readonly PEDirectoriesBuilder _peDirectoriesBuilder;
        private readonly TypeSystemMetadataSerializer _metadataSerializer;
        private readonly BlobBuilder _ilStream;
        private readonly BlobBuilder _mappedFieldDataOpt;
        private readonly BlobBuilder _managedResourcesOpt;
        private readonly ResourceSectionBuilder _nativeResourcesOpt;
        private readonly int _strongNameSignatureSize;
        private readonly MethodDefinitionHandle _entryPointOpt;
        private readonly DebugDirectoryBuilder _debugDirectoryBuilderOpt;
        private readonly CorFlags _corFlags;

        private int _lazyEntryPointAddress;
        private Blob _lazyStrongNameSignature;

        public ManagedPEBuilder(
            PEHeaderBuilder header,
            TypeSystemMetadataSerializer metadataSerializer,
            BlobBuilder ilStream,
            BlobBuilder mappedFieldData = null,
            BlobBuilder managedResources = null,
            ResourceSectionBuilder nativeResources = null,
            DebugDirectoryBuilder debugDirectoryBuilder = null,
            int strongNameSignatureSize = DefaultStrongNameSignatureSize,
            MethodDefinitionHandle entryPoint = default(MethodDefinitionHandle),
            CorFlags flags = CorFlags.ILOnly,
            Func<IEnumerable<Blob>, BlobContentId> deterministicIdProvider = null)
            : base(header, deterministicIdProvider)
        {
            if (header == null)
            {
                Throw.ArgumentNull(nameof(header));
            }

            if (metadataSerializer == null)
            {
                Throw.ArgumentNull(nameof(metadataSerializer));
            }

            if (ilStream == null)
            {
                Throw.ArgumentNull(nameof(ilStream));
            }

            if (strongNameSignatureSize < 0)
            {
                Throw.ArgumentOutOfRange(nameof(strongNameSignatureSize));
            }

            _metadataSerializer = metadataSerializer;
            _ilStream = ilStream;
            _mappedFieldDataOpt = mappedFieldData;
            _managedResourcesOpt = managedResources;
            _nativeResourcesOpt = nativeResources;
            _strongNameSignatureSize = strongNameSignatureSize;
            _entryPointOpt = entryPoint;
            _debugDirectoryBuilderOpt = debugDirectoryBuilder ?? CreateDefaultDebugDirectoryBuilder();
            _corFlags = flags;

            _peDirectoriesBuilder = new PEDirectoriesBuilder();
        }

        private DebugDirectoryBuilder CreateDefaultDebugDirectoryBuilder()
        {
            if (IsDeterministic)
            {
                var builder = new DebugDirectoryBuilder();
                builder.AddReproducibleEntry();
                return builder;
            }

            return null;
        }

        protected override ImmutableArray<Section> CreateSections()
        {
            var builder = ImmutableArray.CreateBuilder<Section>(3);
            builder.Add(new Section(TextSectionName, SectionCharacteristics.MemRead | SectionCharacteristics.MemExecute | SectionCharacteristics.ContainsCode));

            if (_nativeResourcesOpt != null)
            {
                builder.Add(new Section(ResourceSectionName, SectionCharacteristics.MemRead | SectionCharacteristics.ContainsInitializedData));
            }

            if (Header.Machine == Machine.I386 || Header.Machine == 0)
            {
                builder.Add(new Section(RelocationSectionName, SectionCharacteristics.MemRead | SectionCharacteristics.MemDiscardable | SectionCharacteristics.ContainsInitializedData));
            }

            return builder.ToImmutable();
        }

        protected override BlobBuilder SerializeSection(string name, SectionLocation location)
        {
            switch (name)
            {
                case TextSectionName:
                    return SerializeTextSection(location);

                case ResourceSectionName:
                    return SerializeResourceSection(location);

                case RelocationSectionName:
                    return SerializeRelocationSection(location);

                default:
                    throw new ArgumentException(SR.Format(SR.UnknownSectionName, name), nameof(name));
            }
        }

        private BlobBuilder SerializeTextSection(SectionLocation location)
        {
            var sectionBuilder = new BlobBuilder();
            var metadataBuilder = new BlobBuilder();

            var metadataSizes = _metadataSerializer.MetadataSizes;

            var textSection = new ManagedTextSection(
                imageCharacteristics: Header.ImageCharacteristics,
                machine: Header.Machine,
                ilStreamSize: _ilStream.Count,
                metadataSize: metadataSizes.MetadataSize,
                resourceDataSize: _managedResourcesOpt?.Count ?? 0,
                strongNameSignatureSize: _strongNameSignatureSize,
                debugDataSize: _debugDirectoryBuilderOpt?.Size ?? 0,
                mappedFieldDataSize: _mappedFieldDataOpt?.Count ?? 0);

            int methodBodyStreamRva = location.RelativeVirtualAddress + textSection.OffsetToILStream;
            int mappedFieldDataStreamRva = location.RelativeVirtualAddress + textSection.CalculateOffsetToMappedFieldDataStream();
            _metadataSerializer.SerializeMetadata(metadataBuilder, methodBodyStreamRva, mappedFieldDataStreamRva);

            DirectoryEntry debugDirectoryEntry;
            BlobBuilder debugTableBuilderOpt;
            if (_debugDirectoryBuilderOpt != null)
            {
                int debugDirectoryOffset = textSection.ComputeOffsetToDebugDirectory();
                debugTableBuilderOpt = new BlobBuilder(_debugDirectoryBuilderOpt.TableSize);
                _debugDirectoryBuilderOpt.Serialize(debugTableBuilderOpt, location, debugDirectoryOffset);

                // Only the size of the fixed part of the debug table goes here.
                debugDirectoryEntry = new DirectoryEntry(
                    location.RelativeVirtualAddress + debugDirectoryOffset,
                    _debugDirectoryBuilderOpt.TableSize);
            }
            else
            {
                debugTableBuilderOpt = null;
                debugDirectoryEntry = default(DirectoryEntry);
            }

            _lazyEntryPointAddress = textSection.GetEntryPointAddress(location.RelativeVirtualAddress);

            textSection.Serialize(
                sectionBuilder,
                location.RelativeVirtualAddress,
                _entryPointOpt.IsNil ? 0 : MetadataTokens.GetToken(_entryPointOpt),
                _corFlags,
                Header.ImageBase,
                metadataBuilder,
                _ilStream,
                _mappedFieldDataOpt,
                _managedResourcesOpt,
                debugTableBuilderOpt,
                out _lazyStrongNameSignature);

            _peDirectoriesBuilder.AddressOfEntryPoint = _lazyEntryPointAddress;
            _peDirectoriesBuilder.DebugTable = debugDirectoryEntry;
            _peDirectoriesBuilder.ImportAddressTable = textSection.GetImportAddressTableDirectoryEntry(location.RelativeVirtualAddress);
            _peDirectoriesBuilder.ImportTable = textSection.GetImportTableDirectoryEntry(location.RelativeVirtualAddress);
            _peDirectoriesBuilder.CorHeaderTable = textSection.GetCorHeaderDirectoryEntry(location.RelativeVirtualAddress);
            
            return sectionBuilder;
        }

        private BlobBuilder SerializeResourceSection(SectionLocation location)
        {
            Debug.Assert(_nativeResourcesOpt != null);

            var sectionBuilder = new BlobBuilder();
            _nativeResourcesOpt.Serialize(sectionBuilder, location);

            _peDirectoriesBuilder.ResourceTable = new DirectoryEntry(location.RelativeVirtualAddress, sectionBuilder.Count);
            return sectionBuilder;
        }

        private BlobBuilder SerializeRelocationSection(SectionLocation location)
        {
            var sectionBuilder = new BlobBuilder();
            WriteRelocationSection(sectionBuilder, Header.Machine, _lazyEntryPointAddress);

            _peDirectoriesBuilder.BaseRelocationTable = new DirectoryEntry(location.RelativeVirtualAddress, sectionBuilder.Count);
            return sectionBuilder;
        }

        private static void WriteRelocationSection(BlobBuilder builder, Machine machine, int entryPointAddress)
        {
            Debug.Assert(builder.Count == 0);

            builder.WriteUInt32((((uint)entryPointAddress + 2) / 0x1000) * 0x1000);
            builder.WriteUInt32((machine == Machine.IA64) ? 14u : 12u);
            uint offsetWithinPage = ((uint)entryPointAddress + 2) % 0x1000;
            uint relocType = (machine == Machine.Amd64 || machine == Machine.IA64) ? 10u : 3u;
            ushort s = (ushort)((relocType << 12) | offsetWithinPage);
            builder.WriteUInt16(s);
            if (machine == Machine.IA64)
            {
                builder.WriteUInt32(relocType << 12);
            }

            builder.WriteUInt16(0); // next chunk's RVA
        }

        protected internal override PEDirectoriesBuilder GetDirectories()
        {
            return _peDirectoriesBuilder;
        }

        private IEnumerable<Blob> GetContentToSign(BlobBuilder peImage)
        {
            // Signed content includes 
            // - PE header without its alignment padding
            // - all sections including their alignment padding and excluding strong name signature blob

            int remainingHeader = Header.ComputeSizeOfPeHeaders(GetSections().Length);
            foreach (var blob in peImage.GetBlobs())
            {
                if (remainingHeader > 0)
                {
                    int length = Math.Min(remainingHeader, blob.Length);
                    yield return new Blob(blob.Buffer, blob.Start, length);
                    remainingHeader -= length;
                }
                else if (blob.Buffer == _lazyStrongNameSignature.Buffer)
                {
                    yield return new Blob(blob.Buffer, blob.Start, _lazyStrongNameSignature.Start - blob.Start);
                    yield return new Blob(blob.Buffer, _lazyStrongNameSignature.Start + _lazyStrongNameSignature.Length, blob.Length - _lazyStrongNameSignature.Length);
                }
                else
                {
                    yield return new Blob(blob.Buffer, blob.Start, blob.Length);
                }
            }
        }

        public void Sign(BlobBuilder peImage, Func<IEnumerable<Blob>, byte[]> signatureProvider)
        {
            if (peImage == null)
            {
                throw new ArgumentNullException(nameof(peImage));
            }

            if (signatureProvider == null)
            {
                throw new ArgumentNullException(nameof(signatureProvider));
            }

            var content = GetContentToSign(peImage);
            byte[] signature = signatureProvider(content);

            // signature may be shorter (the rest of the reserved space is padding):
            if (signature == null || signature.Length > _lazyStrongNameSignature.Length)
            {
                throw new InvalidOperationException(SR.SignatureProviderReturnedInvalidSignature);
            }

            // TODO: Native csc also calculates and fills checksum in the PE header
            // Using MapFileAndCheckSum() from imagehlp.dll.

            var writer = new BlobWriter(_lazyStrongNameSignature);
            writer.WriteBytes(signature);
        }
    }
}