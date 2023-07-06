{
   Double Commander
   -------------------------------------------------------------------------
   JXL reader implementation (via libjxl library)

   Derived from udcreadwebp.pas

   Copyright (C) 2017-2023 Alexander Koblov (alexx2000@mail.ru)
   Copyright (C) 2023 Egor Gritsenko (egorgrits#gmail.com)

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA
}

unit uDCReadJXL;

{$mode delphi}

interface

uses
  Classes, SysUtils, Graphics, FPImage;

type

  { TDCReaderJXL }

  TDCReaderJXL = class (TFPCustomImageReader)
  protected
    function  InternalCheck(Stream: TStream): Boolean; override;
    procedure InternalRead(Stream: TStream; Img: TFPCustomImage); override;
  end;

  { TJXLImage }

  TJXLImage = class(TFPImageBitmap)
  protected
    class function GetReaderClass: TFPCustomImageReaderClass; override;
    class function GetSharedImageClass: TSharedRasterImageClass; override;
  public
    class function GetFileExtensions: String; override;
  end;

implementation

uses
  InitC, DynLibs, IntfGraphics, GraphType, CTypes, DCOSUtils;

// codestream_header.h 0.8.2
type
  JxlBasicInfo = packed record
    have_container: cint; // JXL_BOOl
    xsize: cint;
    ysize: cint;
    other_stuff: array[0..1023] of cuint8; // we only access size
  end;

// types.h 0.8.2
type
  JxlPixelFormat = packed record
    num_channels: cint;
    data_type: cint; // JxlDataType
    endianness: cint; // JxlEndianness
    align: csize_t;
  end;

// color_encoding.h 0.8.2
type
  JxlColorEncoding = packed record
    stuff: array[0..255] of cuint8; // no need to access members
  end;

const
  // decode.h 0.8.2
  JXL_DEC_BASIC_INFO = $40;
  JXL_DEC_COLOR_ENCODING = $100;
  JXL_DEC_FULL_IMAGE = $1000;
  JXL_DEC_ERROR = 1;
  JXL_DEC_SUCCESS = 0;
  // types.h 0.8.2
  JXL_TYPE_UINT8 = 2;
  JXL_NATIVE_ENDIAN = 0;


var
  JxlDecoderCreate: function(ptr: pointer): pointer; cdecl;
  JxlDecoderSubscribeEvents: function(decoder_ptr: pointer; events: cint): cint; cdecl;
  JXLDecoderGetBasicInfo: function(decoder_ptr: pointer; basic_info_ptr: pointer): cint; cdecl;
  JxlResizableParallelRunner: function(): pointer; cdecl; // <- stub
  JxlDecoderSetParallelRunner: function(decoder_ptr: pointer; strategy: pointer; runner_ptr: pointer): cint; cdecl;
  JxlColorEncodingSetToSRGB: function(encoding_ptr: pointer; gray: cint): cint; cdecl;
  JxlDecoderSetPreferredColorProfile: function(decoder_ptr: pointer; encoder_ptr: pointer): cint; cdecl;
  JxlDecoderSetInput: function(decoder_ptr: pointer; const data: pcuint8; data_size: csize_t): cint; cdecl;
  JxlDecoderCloseInput: function(decoder_ptr: pointer): cint; cdecl;
  JxlDecoderProcessInput: function(decoder_ptr: pointer): cint; cdecl;
  JxlDecoderSetImageOutBuffer: function(decoder_ptr: pointer; pixel_format_ptr: pointer; pixels: pcuint8; count: csize_t): cint; cdecl;
  JxlDecoderDestroy: procedure(decoder_ptr: pointer); cdecl;

  JxlResizableParallelRunnerCreate: function(ptr: pointer): pointer; cdecl;
  JxlResizableParallelRunnerDestroy: procedure(runner_ptr: pointer); cdecl;
  JxlResizableParallelRunnerSetThreads: function(runner_ptr: pointer; threads: csize_t): cint; cdecl;
  JxlResizableParallelRunnerSuggestThreads: function(width: csize_t; height: csize_t): cint; cdecl;


type
  PRGBA = ^TRGBA;
  TRGBA = packed record
    Red, Green,
    Blue, Alpha: Byte;
  end;

{ TDCReaderJXL }

function TDCReaderJXL.InternalCheck(Stream: TStream): Boolean;
begin
  Result:= true; // TODO
end;

procedure TDCReaderJXL.InternalRead(Stream: TStream; Img: TFPCustomImage);
var
  Status: cint;
  Runner: Pointer;
  Decoder: Pointer;
  Data: pcuint8;
  BasicInfo : JxlBasicInfo;
  PixelFormat : JxlPixelFormat;
  ColorEncoding : JxlColorEncoding;
  SuggestedThreads : cint;
  ImageData: PRGBA;
  AWidth, AHeight: cint;
  Desc: TRawImageDescription;
  MemoryStream: TMemoryStream;
  Success: Boolean;
begin
  Runner:= JxlResizableParallelRunnerCreate(nil);
  Decoder:= JxlDecoderCreate(nil);
  JxlDecoderSubscribeEvents(Decoder, JXL_DEC_FULL_IMAGE or JXL_DEC_BASIC_INFO);
  JxlDecoderSetParallelRunner(Decoder, @JxlResizableParallelRunner, Runner);;
  MemoryStream:= Stream as TMemoryStream;
  PixelFormat.num_channels:= 4;
  PixelFormat.data_type:= JXL_TYPE_UINT8;
  PixelFormat.endianness:= JXL_NATIVE_ENDIAN;
  PixelFormat.align:= 0;
  JxlColorEncodingSetToSRGB(@ColorEncoding, 0);
  JxlDecoderSetPreferredColorProfile(Decoder, @ColorEncoding);
  JxlDecoderSetInput(Decoder, MemoryStream.Memory, MemoryStream.Size);
  JxlDecoderCloseInput(Decoder);
  Success:= false;
  Data:= nil;

  while true do
    begin
      Status:= JxlDecoderProcessInput(Decoder);
      if Status = JXL_DEC_ERROR then
        break
      else if Status = JXL_DEC_BASIC_INFO then
      begin
        Status:= JXLDecoderGetBasicInfo(Decoder, @BasicInfo);
        if Status = JXL_DEC_ERROR then break;
        AWidth:= BasicInfo.xsize;
        AHeight:= BasicInfo.ysize;
        SuggestedThreads:= JxlResizableParallelRunnerSuggestThreads(AWidth, AHeight);
        JxlResizableParallelRunnerSetThreads(Runner, SuggestedThreads);
        GetMem(Data, AWidth * AHeight * 4);
        JxlDecoderSetImageOutBuffer(Decoder, @PixelFormat, Data, AWidth * AHeight * 4);
      end
      else if (Status = JXL_DEC_FULL_IMAGE) or (Status = JXL_DEC_SUCCESS) then
      begin
        Success:= true;
        break;
      end
      else if Status <> JXL_DEC_COLOR_ENCODING then
      begin
        break;
      end;
    end;

  if Success then
  begin
    ImageData:= PRGBA(Data);
    // Set output image size
    Img.SetSize(AWidth, AHeight);
    // Initialize image description
    Desc.Init_BPP32_R8G8B8A8_BIO_TTB(Img.Width, Img.Height);
    TLazIntfImage(Img).DataDescription:= Desc;
    // Copy image data
    Move(ImageData^, TLazIntfImage(Img).PixelData^, Img.Width * Img.Height * SizeOf(TRGBA));
  end;

  if Data <> nil then
  begin
    FreeMem(Data)
  end;
  if Decoder <> nil then
  begin
    JxlDecoderDestroy(Decoder);
  end;
  if Runner <> nil then
  begin
    JxlResizableParallelRunnerDestroy(Runner);
  end;
end;

{ TJXLImage }

class function TJXLImage.GetReaderClass: TFPCustomImageReaderClass;
begin
  Result:= TDCReaderJXL;
end;

class function TJXLImage.GetSharedImageClass: TSharedRasterImageClass;
begin
  Result:= TSharedBitmap;
end;

class function TJXLImage.GetFileExtensions: String;
begin
  Result:= 'jxl';
end;


var
  libjxl: TLibHandle;
  libjxl_threads: TLibHandle;

procedure Initialize;
begin

  libjxl:= LoadLibrary('libjxl.so');
  libjxl_threads:= LoadLibrary('libjxl_threads.so');

  if (libjxl <> NilHandle) and (libjxl_threads <> NilHandle) then
  try
    @JxlDecoderCreate:= SafeGetProcAddress(libjxl, 'JxlDecoderCreate');
    @JxlDecoderSubscribeEvents:= SafeGetProcAddress(libjxl, 'JxlDecoderSubscribeEvents');
    @JxlDecoderGetBasicInfo:= SafeGetProcAddress(libjxl, 'JxlDecoderGetBasicInfo');
    @JxlDecoderSetParallelRunner:= SafeGetProcAddress(libjxl, 'JxlDecoderSetParallelRunner');
    @JxlDecoderSetPreferredColorProfile:= SafeGetProcAddress(libjxl, 'JxlDecoderSetPreferredColorProfile');
    @JxlDecoderSetInput:= SafeGetProcAddress(libjxl, 'JxlDecoderSetInput');
    @JxlDecoderCloseInput:= SafeGetProcAddress(libjxl, 'JxlDecoderCloseInput');
    @JxlDecoderProcessInput:= SafeGetProcAddress(libjxl, 'JxlDecoderProcessInput');
    @JxlDecoderSetImageOutBuffer:= SafeGetProcAddress(libjxl, 'JxlDecoderSetImageOutBuffer');
    @JxlDecoderDestroy:= SafeGetProcAddress(libjxl, 'JxlDecoderDestroy');
    @JxlColorEncodingSetToSRGB:= SafeGetProcAddress(libjxl, 'JxlColorEncodingSetToSRGB');
    @JxlDecoderSetParallelRunner:= SafeGetProcAddress(libjxl, 'JxlDecoderSetParallelRunner');

    @JxlResizableParallelRunner:= SafeGetProcAddress(libjxl_threads, 'JxlResizableParallelRunner');
    @JxlResizableParallelRunnerCreate:= SafeGetProcAddress(libjxl_threads, 'JxlResizableParallelRunnerCreate');
    @JxlResizableParallelRunnerDestroy:= SafeGetProcAddress(libjxl_threads, 'JxlResizableParallelRunnerDestroy');
    @JxlResizableParallelRunnerSetThreads:= SafeGetProcAddress(libjxl_threads, 'JxlResizableParallelRunnerSetThreads');
    @JxlResizableParallelRunnerSuggestThreads:= SafeGetProcAddress(libjxl_threads, 'JxlResizableParallelRunnerSuggestThreads');

    // Register image handler and format
    ImageHandlers.RegisterImageReader('JPEG XL Image', 'JXL', TDCReaderJXL);
    TPicture.RegisterFileFormat('jxl', 'JPEG XL Image', TJXLImage);

  except
    Writeln('Couldn''t get the needed functions'' addresses from the loaded libjxl(_threads)');
  end;
end;

initialization
  Initialize;

finalization
  if (libjxl <> NilHandle) then FreeLibrary(libjxl);
  if (libjxl_threads <> NilHandle) then FreeLibrary(libjxl_threads);

end.

