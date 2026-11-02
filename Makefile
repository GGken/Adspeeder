TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME := AdSpeeder
AdSpeeder_FILES := AdSpeeder.m
AdSpeeder_CFLAGS := -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-error
AdSpeeder_FRAMEWORKS := Foundation UIKit AVFoundation WebKit

include $(THEOS_MAKE_PATH)/library.mk
