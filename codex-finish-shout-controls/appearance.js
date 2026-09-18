'use strict';

const languages = ['auto', 'zh', 'en'];
const themes = ['auto', 'dark', 'light'];

function resolveLanguage(preference, editorLanguage = 'zh-CN') {
    if (preference === 'zh' || preference === 'en') return preference;
    return /^zh(?:[-_]|$)/i.test(editorLanguage) ? 'zh' : 'en';
}

function resolveAppearance(languagePreference, theme, editorLanguage) {
    const preference = languages.includes(languagePreference) ? languagePreference : 'auto';
    return {
        language: resolveLanguage(preference, editorLanguage),
        languagePreference: preference,
        theme: themes.includes(theme) ? theme : 'auto'
    };
}

function isAppearanceMessage(message) {
    return Boolean(message && message.type === 'setAppearance' &&
        languages.includes(message.languagePreference) && themes.includes(message.theme));
}

module.exports = { resolveLanguage, resolveAppearance, isAppearanceMessage };
