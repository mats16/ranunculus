#ifndef VOSK_API_H
#define VOSK_API_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VoskModel VoskModel;
typedef struct VoskSpkModel VoskSpkModel;
typedef struct VoskRecognizer VoskRecognizer;

/**
 * Creates the model object.
 * @param model_path the path to the model directory
 * @returns model object or NULL if loading failed
 */
VoskModel *vosk_model_new(const char *model_path);

/**
 * Releases the model memory.
 */
void vosk_model_free(VoskModel *model);

/**
 * Creates the recognizer object.
 * @param model the model to use
 * @param sample_rate the sample rate of the audio
 * @returns recognizer object or NULL if failed
 */
VoskRecognizer *vosk_recognizer_new(VoskModel *model, float sample_rate);

/**
 * Creates the recognizer object with grammar.
 */
VoskRecognizer *vosk_recognizer_new_grm(VoskModel *model, float sample_rate, const char *grammar);

/**
 * Adds speaker model to already initialized recognizer.
 */
void vosk_recognizer_set_spk_model(VoskRecognizer *recognizer, VoskSpkModel *spk_model);

/**
 * Configures recognizer to output n-best results.
 */
void vosk_recognizer_set_max_alternatives(VoskRecognizer *recognizer, int max_alternatives);

/**
 * Enables/disables words with times in the output.
 */
void vosk_recognizer_set_words(VoskRecognizer *recognizer, int words);

/**
 * Enables/disables partial words with times in the output.
 */
void vosk_recognizer_set_partial_words(VoskRecognizer *recognizer, int partial_words);

/**
 * Accept voice data.
 * @param data audio data in PCM 16-bit mono format
 * @param length length of the data in bytes
 * @returns 1 if silence detected (end of utterance), 0 otherwise
 */
int vosk_recognizer_accept_waveform(VoskRecognizer *recognizer, const char *data, int length);

/**
 * Accept voice data as floats.
 */
int vosk_recognizer_accept_waveform_f(VoskRecognizer *recognizer, const float *data, int length);

/**
 * Accept voice data as shorts.
 */
int vosk_recognizer_accept_waveform_s(VoskRecognizer *recognizer, const short *data, int length);

/**
 * Returns speech recognition result (final, after silence detected).
 * JSON format: {"text": "recognized text"}
 */
const char *vosk_recognizer_result(VoskRecognizer *recognizer);

/**
 * Returns partial speech recognition result.
 * JSON format: {"partial": "partial text"}
 */
const char *vosk_recognizer_partial_result(VoskRecognizer *recognizer);

/**
 * Returns speech recognition result, same as result but called at the end of stream.
 */
const char *vosk_recognizer_final_result(VoskRecognizer *recognizer);

/**
 * Resets the recognizer for a new utterance.
 */
void vosk_recognizer_reset(VoskRecognizer *recognizer);

/**
 * Releases the recognizer.
 */
void vosk_recognizer_free(VoskRecognizer *recognizer);

/**
 * Set log level for Kaldi messages.
 * @param log_level the log level (0 = default, -1 = quiet)
 */
void vosk_set_log_level(int log_level);

/**
 * Init, automatically select a CUDA device and allow multithreading.
 */
void vosk_gpu_init(void);

/**
 * Init batch recognizer.
 */
void vosk_gpu_thread_init(void);

#ifdef __cplusplus
}
#endif

#endif /* VOSK_API_H */
