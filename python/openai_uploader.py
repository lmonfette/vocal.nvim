#!/usr/bin/env python3
"""OpenAI audio transcription command-line tool."""
import sys
import json
import os # Kept for os.path.basename for consistency with original file part, though Path.name could be used.
from pathlib import Path
import requests
from typing import Optional, NoReturn # Added NoReturn for exit functions

def _print_error_and_exit(message: str, error_type_str: Optional[str] = None) -> NoReturn:
    """Prints an error message to stderr and exits.

    --- Args:
        message: The error message to print.
        error_type_str: An optional string categorizing the error (used for context).
    """
    full_message = f"Error: {message}"
    if error_type_str:
        full_message = f"Error ({error_type_str}): {message}"
    print(full_message, file=sys.stderr)
    sys.exit(1)

def transcribe_audio(
    api_key: str,
    file_path: Path,
    model_name: str,
    response_format: str,
    temperature: float,
    language: Optional[str] = None,
    timeout_seconds: int = 300,
) -> None:
    """
    Transcribes audio using OpenAI API.
    Prints transcription to stdout or error message to stderr.

    --- Args:
        api_key: OpenAI API key.
        file_path: Path to the audio file.
        model_name: OpenAI model (e.g., "whisper-1").
        response_format: API response format (e.g., "json", "text").
        temperature: Sampling temperature (0-1).
        language: Audio language (ISO 639-1). OpenAI auto-detects if None.
        timeout_seconds: Request timeout. Defaults to 300.
    --- Prints:
        Transcription result to stdout on success.
    """
    url = "https://api.openai.com/v1/audio/transcriptions"
    headers = {"Authorization": f"Bearer {api_key}"}
    data = {
        "model": model_name,
        "response_format": response_format,
        "temperature": str(temperature),  # API expects temperature as string
    }
    if language:
        data["language"] = language

    try:
        with open(file_path, 'rb') as f:
            # Using os.path.basename for consistency with original snippet for the multipart form name
            # Path.name could also be used: file_path.name
            files = {'file': (os.path.basename(file_path), f, 'audio/wav')}
            response = requests.post(url, headers=headers, data=data, files=files, timeout=timeout_seconds)
            response.raise_for_status()  # Raises HTTPError for bad responses
            print(response.text)  # Output successful response to stdout

    except FileNotFoundError:
        _print_error_and_exit(f"Audio file not found: {file_path}", "file_error")
    except PermissionError:
        _print_error_and_exit(f"Permission denied for audio file: {file_path}", "file_error")
    except requests.exceptions.HTTPError as e:
        error_message = f"HTTPError: {str(e)}"
        try:
            error_details = e.response.json()
            if 'error' in error_details and 'message' in error_details['error']:
                error_message = f"OpenAI API Error: {error_details['error']['message']} (Status: {e.response.status_code})"
            else:
                error_message = f"{error_message} - Server response: {e.response.text[:200]}" # Truncate
        except ValueError:  # Response not JSON
            error_message = f"{error_message} - Server response: {e.response.text[:200]}" # Truncate
        _print_error_and_exit(error_message, "api_error")
    except requests.exceptions.Timeout:
        _print_error_and_exit(f"Request to OpenAI API timed out ({timeout_seconds}s).", "network_error")
    except requests.exceptions.RequestException as e:
        _print_error_and_exit(f"Network or request error: {str(e)}", "network_error")
    except Exception as e:
        _print_error_and_exit(f"An unexpected script error occurred: {str(e)}", "script_error")

def main() -> None:
    """
    Parses command-line arguments and initiates audio transcription.

    --- Expects:
        sys.argv[1]: OpenAI API key.
        sys.argv[2]: Path to the audio file.
        sys.argv[3]: OpenAI model name (e.g., "whisper-1").
        sys.argv[4]: API response format (e.g., "json", "text").
        sys.argv[5]: Sampling temperature (float, 0-1).
        sys.argv[6]: Request timeout in seconds (integer).
        sys.argv[7] (optional): Audio language (ISO 639-1).
    """
    if not (7 <= len(sys.argv) <= 8):
        _print_error_and_exit(
            "Usage: script.py <api_key> <file_path> <model> <response_format> <temperature> <timeout_seconds> [language_code]",
            "usage_error"
        )

    api_key_arg = sys.argv[1]
    file_path_str = sys.argv[2]
    model_arg = sys.argv[3]
    response_format_arg = sys.argv[4]
    temperature_str = sys.argv[5]
    timeout_str = sys.argv[6]
    language_arg = sys.argv[7] if len(sys.argv) > 7 else None

    audio_file_path = Path(file_path_str)
    if not audio_file_path.exists():
        _print_error_and_exit(f"Audio file does not exist: {audio_file_path}", "argument_error")
    if not audio_file_path.is_file():
        _print_error_and_exit(f"Specified path is not a file: {audio_file_path}", "argument_error")

    try:
        temperature_arg = float(temperature_str)
        if not (0.0 <= temperature_arg <= 1.0):
             _print_error_and_exit(f"Temperature '{temperature_arg}' must be between 0.0 and 1.0.", "argument_error")
    except ValueError:
        _print_error_and_exit(f"Invalid temperature: '{temperature_str}'. Must be a float.", "argument_error")

    try:
        timeout_arg = int(timeout_str)
        if timeout_arg <= 0:
            _print_error_and_exit("Timeout must be a positive integer.", "argument_error")
    except ValueError:
        _print_error_and_exit(f"Invalid timeout: '{timeout_str}'. Must be an integer.", "argument_error")

    transcribe_audio(
        api_key=api_key_arg,
        file_path=audio_file_path,
        model_name=model_arg,
        response_format=response_format_arg,
        temperature=temperature_arg,
        language=language_arg,
        timeout_seconds=timeout_arg
    )

if __name__ == "__main__":
    main()
